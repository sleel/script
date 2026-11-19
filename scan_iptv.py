#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
山西联通 IPTV 本地组播扫台雷达（纯 Python 3 标准库 · Debian 13 / Linux / Windows 通用，零第三方依赖）

设计目标：
  通过路由器 rtp2httpd（如 http://10.10.66.1:8009/udp/<组播IP>:<端口>）以低并发冷静扫描发现未收录的新频道/隐藏组播流。
  不依赖 ffmpeg，直接解析 MPEG-TS PAT/PMT/SDT 获取视频编码（H.264 / H.265 4K）、音频编码、瞬时码率与流内台名，
  并导出纯净 scan_found.m3u（可直接导入播放器快速翻台认名）和 scan_report.md。

安全保护：
  1. 直接运行 `python3 scan_iptv.py`（不带参数）仅打印帮助，不发起任何网络探测。
  2. 默认单线/低并发（-w 2）+ IGMP 冷却间隔，避免打满 rtp2httpd（maxclients=10）或影响家中看电视。
  3. 自动读取同目录 atv.m3u 与 pcap_channels.json 跳过已知频道，支持断点续扫（--resume）与 Ctrl+C 安全保存。

常用模式：
  python3 scan_iptv.py --mode formula                           # 极速(~1分钟)：仅扫 226.0.2.x 空号 IP 对应公式端口 8000+(d-11)*8
  python3 scan_iptv.py --mode fast                              # 快速雷达(~2分钟)：公式空洞 + 226.0.1.235~254 邻近 4K 段
  python3 scan_iptv.py --mode gaps                              # 插空回扫：全部空号 226.0.2.x × 历史非公式端口池（约15~20分钟）
  python3 scan_iptv.py --ips 226.0.2.1-254 --ports 8000-9920:4  # 自定义网段与端口步长扫描（随时 Ctrl+C 下次 --resume 续扫）
"""

import argparse
import datetime
import json
import os
import re
import signal
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

DEFAULT_PROXY_PREFIX = "http://10.10.66.1:8009"

# 绕过环境变量或本地代理，直连局域网 rtp2httpd
_DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# 已知历史非公式端口保底池（即使无 pcap_channels.json 也能识别常见特例端口）
_FALLBACK_SPECIAL_PORTS = [
    8004, 8012, 8268, 8276, 8284, 8292, 8308, 8316,
    9006, 9010, 9108, 9116, 9124, 9132, 9140, 9148, 9152, 9156, 9164, 9168, 9172, 9176, 9180, 9188,
    9772, 9820, 9832, 9836, 9840, 9848, 9856, 9860, 9864, 9872, 9876, 9880, 9884, 9888, 9892, 9896,
]

_VIDEO_TYPES = {
    0x01: "MPEG1",
    0x02: "MPEG2",
    0x10: "MPEG4",
    0x1B: "H.264",
    0x24: "H.265/HEVC",
    0x42: "AVS+",
    0xD2: "AVS2",
    0xEA: "VC-1",
}

_AUDIO_TYPES = {
    0x03: "MP2",
    0x04: "MP3",
    0x0F: "AAC",
    0x11: "HE-AAC",
    0x81: "AC3",
    0x87: "E-AC3",
}


def _parse_ip_spec(spec: str) -> list:
    """解析 IP 列表或范围，例如 '226.0.2.1-254' 或 '226.0.1.242,226.0.1.243'。"""
    ips = []
    seen = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        m = re.fullmatch(r"(\d+\.\d+\.\d+)\.(\d+)-(\d+)", part)
        if m:
            prefix = m.group(1)
            a, b = int(m.group(2)), int(m.group(3))
            if not (0 <= a <= 255 and 0 <= b <= 255):
                raise ValueError(f"无效 IP 范围: {part}")
            step = 1 if a <= b else -1
            for d in range(a, b + step, step):
                ip = f"{prefix}.{d}"
                if ip not in seen:
                    seen.add(ip)
                    ips.append(ip)
            continue
        if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", part):
            if part not in seen:
                seen.add(part)
                ips.append(part)
            continue
        raise ValueError(f"不支持的 IP 表达式: {part}（示例: 226.0.2.1-254）")
    return ips


def _parse_port_spec(spec: str) -> list:
    """解析端口列表或带步长区间，例如 '8000-9920:4' 或 '2118,2120-2130'。"""
    ports = []
    seen = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        m = re.fullmatch(r"(\d+)-(\d+)(?::(\d+))?", part)
        if m:
            a, b = int(m.group(1)), int(m.group(2))
            step = int(m.group(3) or 1)
            if not (1 <= a <= 65535 and 1 <= b <= 65535 and step >= 1):
                raise ValueError(f"无效端口区间: {part}")
            for p in range(min(a, b), max(a, b) + 1, step):
                if p not in seen:
                    seen.add(p)
                    ports.append(p)
            continue
        if part.isdigit() and 1 <= int(part) <= 65535:
            p = int(part)
            if p not in seen:
                seen.add(p)
                ports.append(p)
            continue
        raise ValueError(f"不支持的端口表达式: {part}（示例: 8000-9920:4 或 2118,2120-2130）")
    return ports


def _load_known_mcasts(blueprint_path: str, pcap_json_path: str) -> tuple:
    """加载已知组播集合（避免重复上报已有台）及抓包统计出的特殊非公式端口池。"""
    known = {}
    special_ports = set(_FALLBACK_SPECIAL_PORTS)

    if pcap_json_path and os.path.exists(pcap_json_path):
        with open(pcap_json_path, "r", encoding="utf-8") as f:
            pcap_data = json.load(f)
        for ch in pcap_data.get("all_channels", []):
            mc = ch.get("mcast", "")
            if mc:
                known.setdefault(mc, ch.get("name", ""))
                ip, _, p_s = mc.partition(":")
                if ip.startswith("226.0.2.") and p_s.isdigit():
                    d_oct = int(ip.split(".")[3])
                    p = int(p_s)
                    if p != 8000 + (d_oct - 11) * 8:
                        special_ports.add(p)

    if blueprint_path and os.path.exists(blueprint_path):
        with open(blueprint_path, "r", encoding="utf-8-sig", errors="ignore") as f:
            lines = [l.rstrip("\r\n") for l in f if l.strip()]
        i = 0
        while i < len(lines):
            if lines[i].startswith("#EXTINF:") and i + 1 < len(lines):
                title = lines[i].split(",")[-1].strip()
                url = lines[i + 1].strip()
                m = re.search(r"(\d+\.\d+\.\d+\.\d+:\d+)(?:$|\?)", url)
                if m:
                    known.setdefault(m.group(1), title)
                i += 2
            else:
                i += 1

    return known, sorted(special_ports)


def _find_ts_sync(buf: bytes) -> int:
    """定位三帧连续 188 字节 0x47 MPEG-TS 同步偏移；无效返回 -1。"""
    n = len(buf)
    if n >= 377:
        for i in range(min(n - 376, 512)):
            if buf[i] == 0x47 and buf[i + 188] == 0x47 and buf[i + 376] == 0x47:
                return i
    if n >= 189:
        for i in range(min(n - 188, 188)):
            if buf[i] == 0x47 and buf[i + 188] == 0x47:
                return i
    return -1


def _decode_dvb_text(raw: bytes) -> str:
    """解析 DVB SDT 文本字段（兼容 UTF-8 / GB18030 与字符集控制前缀）。"""
    if not raw:
        return ""
    enc = None
    data = raw
    if raw[0] == 0x15:
        enc = "utf-8"
        data = raw[1:]
    elif raw[0] in (0x13, 0x14):
        enc = "gb18030"
        data = raw[1:]
    elif raw[0] == 0x10 and len(raw) >= 3:
        data = raw[3:]
    elif raw[0] < 0x20:
        data = raw[1:]

    for codec in ([enc] if enc else []) + ["utf-8", "gb18030", "latin1"]:
        try:
            txt = data.decode(codec).strip()
            txt = "".join(ch for ch in txt if ch.isprintable()).strip()
            if txt:
                return txt
        except Exception:
            continue
    return ""


def _extract_psi_section(pkt: bytes) -> bytes:
    """从单个 188B TS 包中提取承载新 PSI/SI 段的起始切片。"""
    if not (pkt[1] & 0x40):
        return b""
    afc = (pkt[3] >> 4) & 0x03
    if afc == 1:
        pos = 4
    elif afc == 3:
        pos = 5 + pkt[4]
    else:
        return b""
    if pos >= 188:
        return b""
    ptr = pkt[pos]
    sec_start = pos + 1 + ptr
    if sec_start + 3 >= 188:
        return b""
    return pkt[sec_start:]


def _inspect_mpeg_ts(buf: bytes) -> dict:
    """解析采样 TS 流里的 PAT、PMT（音视频编码）与 SDT（流内频道名）。"""
    start = _find_ts_sync(buf)
    if start < 0:
        return {"is_ts": False}

    pmt_pids = set()
    video_codecs = []
    audio_codecs = []
    sdt_names = []
    pids_seen = set()

    for off in range(start, len(buf) - 187, 188):
        pkt = buf[off:off + 188]
        if pkt[0] != 0x47:
            continue
        pid = ((pkt[1] & 0x1F) << 8) | pkt[2]
        pids_seen.add(pid)
        sec = _extract_psi_section(pkt)
        if len(sec) < 8:
            continue

        table_id = sec[0]
        sec_len = ((sec[1] & 0x0F) << 8) | sec[2]
        sec_end = min(len(sec), 3 + sec_len - 4)

        # PAT (PID 0x0000)
        if pid == 0x0000 and table_id == 0x00 and sec_end >= 12:
            for j in range(8, sec_end - 3, 4):
                prog = (sec[j] << 8) | sec[j + 1]
                mpid = ((sec[j + 2] & 0x1F) << 8) | sec[j + 3]
                if prog != 0:
                    pmt_pids.add(mpid)

        # PMT
        elif pid in pmt_pids and table_id == 0x02 and sec_end >= 12:
            prog_info_len = ((sec[10] & 0x0F) << 8) | sec[11]
            j = 12 + prog_info_len
            while j + 5 <= sec_end:
                stype = sec[j]
                es_len = ((sec[j + 3] & 0x0F) << 8) | sec[j + 4]
                if stype in _VIDEO_TYPES and _VIDEO_TYPES[stype] not in video_codecs:
                    video_codecs.append(_VIDEO_TYPES[stype])
                elif stype in _AUDIO_TYPES and _AUDIO_TYPES[stype] not in audio_codecs:
                    audio_codecs.append(_AUDIO_TYPES[stype])
                elif stype == 0x06 and "AC3/Teletext" not in audio_codecs:
                    audio_codecs.append("AC3/PES")
                j += 5 + es_len

        # SDT actual transport stream (PID 0x0011, table_id 0x42)
        elif pid == 0x0011 and table_id == 0x42 and sec_end >= 16:
            j = 11
            while j + 5 <= sec_end:
                dloop_len = ((sec[j + 3] & 0x0F) << 8) | sec[j + 4]
                k = j + 5
                k_end = min(sec_end, k + dloop_len)
                while k + 2 <= k_end:
                    dtag = sec[k]
                    dlen = sec[k + 1]
                    if dtag == 0x48 and k + 2 + dlen <= k_end and dlen >= 3:
                        prov_len = sec[k + 3]
                        name_idx = k + 4 + prov_len
                        if name_idx < k + 2 + dlen:
                            nlen = sec[name_idx]
                            raw_name = sec[name_idx + 1:name_idx + 1 + nlen]
                            nm = _decode_dvb_text(raw_name)
                            if nm and nm not in sdt_names:
                                sdt_names.append(nm)
                    k += 2 + dlen
                j += 5 + dloop_len

    return {
        "is_ts": True,
        "video": "/".join(video_codecs) if video_codecs else "-",
        "audio": "/".join(audio_codecs) if audio_codecs else "-",
        "sdt_name": sdt_names[0] if sdt_names else "",
        "pid_count": len(pids_seen),
    }


def _probe_mcast_target(
    target: str,
    proxy_prefix: str,
    timeout: float = 2.5,
    sample_sec: float = 2.2,
    sample_bytes: int = 8 * 1024 * 1024,
    cooldown: float = 0.15,
) -> dict:
    """探测单个 IP:Port，确认真 TS 流后动态采样（遇 SDT 且 >=0.75s 提前结束，最长 2.2s）提取编码/码率/台名。"""
    url = f"{proxy_prefix.rstrip('/')}/udp/{target}"
    req = urllib.request.Request(url, headers={"Connection": "close", "User-Agent": "Mozilla/5.0"})
    t0 = time.perf_counter()
    try:
        with _DIRECT_OPENER.open(req, timeout=timeout) as resp:
            first = resp.read(8192)
            first_ms = round((time.perf_counter() - t0) * 1000)
            if _find_ts_sync(first) < 0:
                return {"mcast": target, "ok": False, "detail": f"非TS响应({len(first)}B)"}

            chunks = [first]
            total = len(first)
            t_sample_start = time.perf_counter()
            has_sdt = b"\x47\x40\x11" in first
            while total < sample_bytes:
                el = time.perf_counter() - t_sample_start
                if el >= sample_sec or (el >= 0.75 and has_sdt):
                    break
                blk = resp.read(min(32768, sample_bytes - total))
                if not blk:
                    break
                chunks.append(blk)
                total += len(blk)
                if not has_sdt and b"\x47\x40\x11" in blk:
                    has_sdt = True
            sample_dur = max(0.05, time.perf_counter() - t_sample_start)
            buf = b"".join(chunks)
            psi = _inspect_mpeg_ts(buf)
            mbps = round(((total - len(first)) * 8.0 / sample_dur / 1_000_000) if total > len(first) else 0.0, 2)
            return {
                "mcast": target,
                "url": url,
                "ok": True,
                "first_ms": first_ms,
                "mbps": mbps,
                "video": psi.get("video", "-"),
                "audio": psi.get("audio", "-"),
                "sdt_name": psi.get("sdt_name", ""),
                "pid_count": psi.get("pid_count", 0),
                "bytes": total,
            }
    except urllib.error.HTTPError as he:
        return {"mcast": target, "ok": False, "detail": f"HTTP {he.code}"}
    except Exception as exc:
        return {"mcast": target, "ok": False, "detail": f"ERR:{type(exc).__name__}"}
    finally:
        if cooldown > 0:
            time.sleep(cooldown)


def _build_targets(
    mode: str,
    ips_spec: str,
    ports_spec: str,
    known: dict,
    special_ports: list,
    include_known: bool,
) -> list:
    """根据扫台模式生成去重后的有序候选 (ip:port) 清单。"""
    targets = []
    seen = set()

    def _add(mc: str):
        if mc not in seen and (include_known or mc not in known):
            seen.add(mc)
            targets.append(mc)

    if mode == "custom":
        ips = _parse_ip_spec(ips_spec)
        ports = _parse_port_spec(ports_spec)
        for ip in ips:
            for p in ports:
                _add(f"{ip}:{p}")
        return targets

    # formula & fast & gaps 都优先囊括 226.0.2.1..254 公式补洞
    for d in range(1, 255):
        p = 8000 + (d - 11) * 8
        if 1 <= p <= 65535:
            _add(f"226.0.2.{d}:{p}")

    if mode in ("fast", "gaps"):
        # 226.0.1.235..254 x 2115..2132（4K 邻近扩展区）
        for d in range(235, 255):
            for p in range(2115, 2133):
                _add(f"226.0.1.{d}:{p}")

    if mode == "gaps":
        # 对未收录的 226.0.2.x 空号 IP 搭配历史非公式特殊端口回扫
        known_2_octets = {int(mc.split(":")[0].split(".")[3]) for mc in known if mc.startswith("226.0.2.")}
        for d in range(1, 255):
            if d in known_2_octets and not include_known:
                continue
            for p in special_ports:
                _add(f"226.0.2.{d}:{p}")

    return targets


def _write_outputs(
    hits: list,
    scanned_count: int,
    total_targets: int,
    known: dict,
    out_m3u_path: str,
    report_path: str,
    elapsed_sec: float,
):
    """写出扫描发现的可播放 M3U 与带编码/码率分析的 Markdown 报告。"""
    m3u_lines = ["#EXTM3U"]
    md_lines = [
        "# 山西联通 IPTV 本地扫描结果",
        "",
        f"- **扫描进度**：已完成 `{scanned_count}/{total_targets}` 个候选地址（耗时 `{elapsed_sec:.1f}s`），共发现可用组播流 **{len(hits)}** 条。",
        "",
        "| # | 组播地址 | 推荐命名 | 流内 SDT 名 | 视频编码 | 音频 | 估算码率 | 首包 | 播放地址 |",
        "| :---: | :--- | :--- | :--- | :---: | :---: | :---: | :---: | :--- |",
    ]

    for idx, item in enumerate(sorted(hits, key=lambda x: tuple(int(v) for v in x["mcast"].replace(":", ".").split("."))), 1):
        mc = item["mcast"]
        known_name = known.get(mc, "")
        sdt = item.get("sdt_name", "")
        vid = item.get("video", "-")
        mbps = item.get("mbps", 0.0)
        tag_4k = " [4K/高码]" if ("H.265" in vid or mbps >= 15.0) else ""
        if known_name:
            disp = f"{known_name}(已知)"
        elif sdt:
            disp = f"{sdt}{tag_4k}"
        else:
            disp = f"未知_{mc}{tag_4k}"
        m3u_lines.append(f'#EXTINF:-1 tvg-name="{sdt or known_name or disp}" group-title="新扫发现",{disp}')
        m3u_lines.append(item["url"])
        md_lines.append(
            f"| {idx} | `{mc}` | {disp} | `{sdt or '-'}` | `{vid}` | `{item.get('audio', '-')}` | "
            f"`{mbps:.2f} Mbps` | `{item.get('first_ms', 0)}ms` | `{item['url']}` |"
        )

    if not hits:
        md_lines.extend(["", "> 本次范围未发现新增可用组播流。"])

    with open(out_m3u_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(m3u_lines) + "\n")
    with open(report_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(md_lines) + "\n")


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(
        description="山西联通 IPTV 本地组播扫台雷达（不带参数只打印帮助，不扫描）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "常用示例:\n"
            "  python3 scan_iptv.py --mode formula                           # 极速公式补洞 (~1分钟，仅扫 226.0.2.x 公式空位)\n"
            "  python3 scan_iptv.py --mode fast                              # 快速雷达 (~2~4分钟，公式补洞 + 226.0.1.x 4K邻近段)\n"
            "  python3 scan_iptv.py --mode gaps                              # 空号插空扫 (226.0.2.x 空号 × 历史特殊端口池)\n"
            "  python3 scan_iptv.py --ips 226.0.2.1-254 --ports 8000-9920:4  # 自定义大范围扫描，支持 --resume 断点续扫\n"
            "  python3 scan_iptv.py --resume                                 # 从 scan_state.json 断点继续未完成的扫描\n"
        ),
    )
    parser.add_argument("--mode", choices=["formula", "fast", "gaps", "custom"], default=None, help="扫描预设模式")
    parser.add_argument("--ips", default="", help="自定义 IP 或区间（配合 custom 或自动触发 custom，如 226.0.2.1-254）")
    parser.add_argument("--ports", default="", help="自定义端口或步长区间（如 8000-9920:4 或 2118,2120-2130）")
    parser.add_argument("--resume", action="store_true", help="读取 scan_state.json 继续未完成的扫描")
    parser.add_argument("--include-known", action="store_true", help="不跳过 atv.m3u / pcap_channels.json 已收录地址")
    parser.add_argument("--blueprint", default=os.path.join(base_dir, "atv.m3u"), help="已知频道参考蓝本 atv.m3u")
    parser.add_argument("--pcap-json", default=os.path.join(base_dir, "pcap_channels.json"), help="抓包频道数据 pcap_channels.json")
    parser.add_argument("--state-json", default=os.path.join(base_dir, "scan_state.json"), help="扫描断点进度文件")
    parser.add_argument("-o", "--out-m3u", default=os.path.join(base_dir, "scan_found.m3u"), help="输出扫描 M3U 路径")
    parser.add_argument("--report", default=os.path.join(base_dir, "scan_report.md"), help="输出扫描说明报告路径")
    parser.add_argument("--proxy-prefix", default=DEFAULT_PROXY_PREFIX, help="rtp2httpd 地址前缀")
    parser.add_argument("-w", "--workers", type=int, default=2, help="并发扫描路数（默认 2，请勿设过高以免抢占 rtp2httpd 名额）")
    parser.add_argument("--timeout", type=float, default=2.5, help="单路握手超时秒数（默认 2.5）")
    parser.add_argument("--cooldown", type=float, default=0.15, help="单次扫描后 IGMP 冷却秒数（默认 0.15）")
    args = parser.parse_args()

    if args.ips or args.ports:
        if not (args.ips and args.ports):
            parser.error("自定义扫描需同时提供 --ips 和 --ports，例如: --ips 226.0.1.235-254 --ports 2115-2135")
        if args.mode and args.mode != "custom":
            parser.error("--ips/--ports 仅用于自定义扫描，请勿与其它 --mode 混用")
        args.mode = "custom"

    if not args.mode and not args.resume:
        parser.print_help()
        print("\n提示：直接运行不执行任何扫描，请指定 --mode (formula/fast/gaps)、--ips/--ports 或 --resume。")
        return

    known, special_ports = _load_known_mcasts(args.blueprint, args.pcap_json)

    if args.resume:
        if not os.path.exists(args.state_json):
            raise FileNotFoundError(f"未找到断点文件 {args.state_json}，请先发起一次扫描。")
        with open(args.state_json, "r", encoding="utf-8") as f:
            state = json.load(f)
        all_targets = state["targets"]
        done_set = set(state.get("done", []))
        hits_by_mc = {x["mcast"]: x for x in state.get("hits", [])}
        print(f"[断点续扫] 已完成 {len(done_set)}/{len(all_targets)}，已发现 {len(hits_by_mc)} 条流，继续扫描剩余 {len(all_targets) - len(done_set)} 个...")
    else:
        all_targets = _build_targets(args.mode, args.ips, args.ports, known, special_ports, args.include_known)
        done_set = set()
        hits_by_mc = {}
        state = {"mode": args.mode, "created_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "targets": all_targets, "done": [], "hits": []}
        print(f"[本地扫台] 模式={args.mode} | 已知去重={len(known)} 路 | 待扫目标={len(all_targets)} 个 | 并发={args.workers} | 冷却={args.cooldown:.2f}s")

    pending = [t for t in all_targets if t not in done_set]
    if not pending:
        _write_outputs(list(hits_by_mc.values()), len(done_set), len(all_targets), known, args.out_m3u, args.report, 0.0)
        print(f"[本地扫台] 目标已全部扫描完成，共发现 {len(hits_by_mc)} 条流 -> {args.out_m3u}")
        return

    stop_requested = False

    def _on_sigint(_sig, _frame):
        nonlocal stop_requested
        stop_requested = True
        print("\n⚠️ 收到中断信号，正在等待当前在途探测收尾并保存断点...")

    prev_handler = signal.signal(signal.SIGINT, _on_sigint)
    t0 = time.perf_counter()

    def _save_state():
        state["done"] = sorted(done_set)
        state["hits"] = list(hits_by_mc.values())
        with open(args.state_json, "w", encoding="utf-8", newline="\n") as f:
            json.dump(state, f, ensure_ascii=False, indent=2)

    try:
        with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
            batch_size = max(20, args.workers * 10)
            for idx_start in range(0, len(pending), batch_size):
                if stop_requested:
                    break
                batch = pending[idx_start:idx_start + batch_size]
                futs = {
                    pool.submit(_probe_mcast_target, mc, args.proxy_prefix, args.timeout, 2.2, 8 * 1024 * 1024, args.cooldown): mc
                    for mc in batch
                }
                for fut in as_completed(futs):
                    res = fut.result()
                    done_set.add(res["mcast"])
                    if res["ok"]:
                        hits_by_mc[res["mcast"]] = res
                        sdt_tag = f" SDT={res['sdt_name']}" if res.get("sdt_name") else ""
                        print(f"  ✔ 发现 [{len(done_set)}/{len(all_targets)}] {res['mcast']:<20s} | {res['video']:<10s} | {res['mbps']:>5.2f} Mbps{sdt_tag}")
                _save_state()
                if (len(done_set) % 50) < len(batch) or len(done_set) == len(all_targets):
                    elapsed = time.perf_counter() - t0
                    rate = max(0.01, (len(done_set) - (len(all_targets) - len(pending))) / max(0.1, elapsed))
                    eta = (len(all_targets) - len(done_set)) / rate
                    print(f"  ... 进度 {len(done_set)}/{len(all_targets)} ({len(hits_by_mc)} 条命中 | 已耗时 {elapsed:.0f}s | 预计剩余 {eta:.0f}s)")
    finally:
        signal.signal(signal.SIGINT, prev_handler)
        _save_state()

    elapsed_total = time.perf_counter() - t0
    _write_outputs(list(hits_by_mc.values()), len(done_set), len(all_targets), known, args.out_m3u, args.report, elapsed_total)
    print(f"[扫描{'暂停已保存断点' if stop_requested else '完成'}] 已扫 {len(done_set)}/{len(all_targets)} | 命中 {len(hits_by_mc)} 条 | 耗时 {elapsed_total:.1f}s")
    print(f"  ├─ 可直接翻台 M3U -> {args.out_m3u}")
    print(f"  ├─ 扫描明细报告   -> {args.report}")
    print(f"  └─ 断点状态文件   -> {args.state_json}" + ("（下次跑 --resume 继续）" if stop_requested else ""))


if __name__ == "__main__":
    main()
