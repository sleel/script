#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
山西联通 IPTV 本地/LXC 独立 M3U 构建工具（单文件零第三方依赖，不依赖任何 EPG 脚本）

安全保护：直接运行 `python3 build_m3u.py`（不带参数）不会执行任何解析、探测或改写，仅显示命令说明。

四阶段流程与常用参数：
  -u, --unpack   阶段1：读取抓包 iptv_sig.pcap 解包，对比蓝本 atv.m3u 输出差异说明（pcap_channels.json / unpack_diff.md）
  -l, --live     阶段2：对蓝本 atv.m3u 全部直播源逐一测活，仅输出超时/失效警告列表并生成 live_sources.json（不做交互删减）
  -p, --probe    阶段3：先读取 live_sources.json 为失效台检索抓包/备源替代方案并按需决策（替换/保留/删减），再探测 RTSP 回看/时移（verified_sources.json）
  -m, --merge    阶段4：纯离线确定性合并蓝本 atv.m3u 与 verified_sources.json，输出 atv_catchup.m3u、channels_epg.json 与 m3u_report.md
  -e, --execute  一键完整执行全流程（等价于依次执行 -u -> -l -> -p -> -m）

示例：
  python3 build_m3u.py                                         # 仅查看说明，不执行
  python3 build_m3u.py -e                                      # 跑完整流程（-u -> -l[纯测活报警] -> -p[找替代+决策+测回看] -> -m[纯合并]）
  python3 build_m3u.py -e --on-dead auto                       # 完整流程：有可用替代自动替换，无替代自动删减失效源
  python3 build_m3u.py -l                                      # 单独跑阶段2：测活蓝本直播源并打印异常警示
  python3 build_m3u.py -p                                      # 单独跑阶段3：排查替代源、处理失效台并测试 RTSP 回看/时移
  python3 build_m3u.py -m -t "https://.../epg.xml.gz"          # 单独跑阶段4：纯合并生成最终列表并填入公开 EPG 地址
"""

import argparse
import datetime
import gzip
import json
import os
import re
import socket
import struct
import sys
import time
import urllib.error
import urllib.request
import zlib
from concurrent.futures import ThreadPoolExecutor

DEFAULT_PROXY_PREFIX = "http://10.10.66.1:8009"
DEFAULT_TVG_URL = "https://YOUR_PUBLIC_EPG_REPO/epg.xml.gz"

PCAP_MAGICS = {
    b"\xa1\xb2\xc3\xd4": ">",
    b"\xd4\xc3\xb2\xa1": "<",
    b"\xa1\xb2\x3c\x4d": ">",
    b"\x4d\x3c\xb2\xa1": "<",
}

# 内网 RTSP 探针强制绕过系统代理（如 Windows 127.0.0.1:7890 或环境变量代理）
_DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _extract_tcp_streams(pcap_path: str) -> list:
    """解析标准 tcpdump .pcap（兼容 Ethernet / VLAN / SLL / SLL2 / Raw IP / 回环）并重组 TCP 流。"""
    flows = {}
    with open(pcap_path, "rb") as f:
        magic = f.read(4)
        if magic == b"\x0a\x0d\x0d\x0a":
            raise ValueError("检测到 pcapng 格式，请转换为传统 .pcap 或使用 tcpdump -s 0 -w out.pcap 抓包。")
        if magic not in PCAP_MAGICS:
            raise ValueError(f"非标准 .pcap 文件格式: magic={magic.hex()}")
        endian = PCAP_MAGICS[magic]

        ghdr = f.read(20)
        if len(ghdr) < 20:
            raise ValueError("pcap 文件全局头被截断")
        _, _, _, _, _, linktype = struct.unpack(endian + "HHIIII", ghdr)

        while True:
            phdr = f.read(16)
            if len(phdr) < 16:
                break
            _, _, cap_len, _ = struct.unpack(endian + "IIII", phdr)
            if cap_len == 0 or cap_len > 262144:
                break
            pkt = f.read(cap_len)
            if len(pkt) < cap_len:
                break

            if linktype == 1:
                if len(pkt) < 14:
                    continue
                eth_type, off = struct.unpack("!H", pkt[12:14])[0], 14
            elif linktype == 113:
                if len(pkt) < 16:
                    continue
                eth_type, off = struct.unpack("!H", pkt[14:16])[0], 16
            elif linktype == 276:
                if len(pkt) < 20:
                    continue
                eth_type, off = struct.unpack("!H", pkt[0:2])[0], 20
            elif linktype in (0, 108):
                if len(pkt) < 4:
                    continue
                fam = struct.unpack(endian + "I", pkt[:4])[0]
                eth_type, off = (0x0800 if fam == 2 else 0), 4
            elif linktype == 101:
                if not pkt:
                    continue
                eth_type, off = (0x0800 if (pkt[0] >> 4) == 4 else 0), 0
            else:
                continue

            while eth_type in (0x8100, 0x88A8, 0x9100) and len(pkt) >= off + 4:
                eth_type = struct.unpack("!H", pkt[off + 2:off + 4])[0]
                off += 4
            if eth_type != 0x0800 or len(pkt) < off + 20:
                continue

            ihl = (pkt[off] & 0x0F) * 4
            if ihl < 20 or len(pkt) < off + ihl:
                continue
            tot_len = struct.unpack("!H", pkt[off + 2:off + 4])[0]
            if pkt[off + 9] != 6 or len(pkt) < off + ihl + 20:
                continue

            src_ip = socket.inet_ntoa(pkt[off + 12:off + 16])
            dst_ip = socket.inet_ntoa(pkt[off + 16:off + 20])
            tcp_off = off + ihl
            sport, dport, seq = struct.unpack("!HHI", pkt[tcp_off:tcp_off + 8])
            doff = (pkt[tcp_off + 12] >> 4) * 4
            if doff < 20:
                continue
            p_start = tcp_off + doff
            p_end = min(len(pkt), off + tot_len) if tot_len >= ihl + doff else len(pkt)
            if p_end > p_start:
                flows.setdefault((src_ip, sport, dst_ip, dport), []).append((seq, pkt[p_start:p_end]))

    streams = []
    for segs in flows.values():
        segs.sort(key=lambda x: x[0])
        buf, cur = bytearray(), None
        for seq, data in segs:
            if cur is None or seq >= cur:
                buf.extend(data)
                cur = seq + len(data)
            elif seq + len(data) > cur:
                buf.extend(data[cur - seq:])
                cur = seq + len(data)
        streams.append(bytes(buf))
    return streams


def _decode_frameset(data: bytes):
    """提取 frameset_builder.jsp HTTP 响应体并处理 chunked 与 gzip 压缩。"""
    i = data.lower().find(b"x-frame-apiname: frameset_builder")
    if i < 0:
        return None
    h = data.rfind(b"HTTP/1.", 0, i)
    he = data.find(b"\r\n\r\n", h) if h >= 0 else -1
    if he < 0:
        return None

    head, pos = data[h:he], he + 4
    lower_head = head.lower()
    if b"chunked" in lower_head:
        body = bytearray()
        while True:
            nl = data.find(b"\r\n", pos)
            if nl < 0:
                break
            try:
                size = int(data[pos:nl].split(b";")[0].strip(), 16)
            except ValueError:
                break
            pos = nl + 2
            if size == 0:
                break
            body.extend(data[pos:pos + size])
            pos += size + 2
        body = bytes(body)
    else:
        m = re.search(rb"(?i)content-length:\s*(\d+)", head)
        body = data[pos:pos + int(m.group(1))] if m else data[pos:]

    if b"gzip" in lower_head or body[:2] == b"\x1f\x8b":
        try:
            body = gzip.decompress(body)
        except Exception:
            try:
                body = zlib.decompress(body, -15)
            except Exception:
                return None
    return body if len(body) > 10000 else None


def _smart_decode(raw: bytes):
    for enc in ("utf-8", "gbk", "gb18030"):
        try:
            return raw.decode(enc), enc
        except UnicodeDecodeError:
            continue
    return raw.decode("gbk", errors="replace"), "gbk?"


def _norm_4k(name: str) -> str:
    return name.replace("超高清", "4K").replace(" ", "").upper()


# 仅用于识别“同频道不同清晰度/命名方式”，不把真正换台的名称强行归并
_CHANNEL_ALIASES = {
    "福建东南卫视": "东南卫视",
    "旅游卫视": "海南卫视",
    "山西黄河": "黄河卫视",
    "山西经济资讯": "山西经济",
    "山西经济科技": "山西经济",
    "山西社会法治": "山西社会法治",
    "央视文化精品": "文化精品",
    "老故事": "中央新影老故事",
    "中国教育1": "CETV1",
    "中国教育台1": "CETV1",
    "中国教育2": "CETV2",
    "中国教育台2": "CETV2",
    "中国教育4": "CETV4",
    "中国教育台4": "CETV4",
    "早期教育": "CETV早期教育",
    "纪实科教": "北京纪实科教",
    "卡酷动画": "卡酷少儿",
    "太原新闻综合": "太原1",
    "太原百姓": "太原2",
    "太原社教法制": "太原3",
    "阳泉": "阳泉新闻综合",
    "朔州1": "朔州1",
    "朔州2": "朔州2",
    "娄烦": "娄烦综合",
    "稷山": "稷山电视台",
    "CCTV超高清": "CCTV4K",
    "运城3": "运城盐湖",
    "环球购物": "聚鲨环球精选",
    "空中课堂": "CETV4",
}


def _canon_channel_name(s: str) -> str:
    """规范化频道名称，过滤不同清晰度/台标前后缀差异以识别同台异流。"""
    raw = re.sub(r"[\s\-_（）\(\)\[\]【】]", "", s).upper()
    if re.match(r"^CCTV4(?:HD)?(美洲|欧洲)$", raw):
        return "CCTV4" + ("美洲" if "美洲" in s else "欧洲")
    n = raw.replace("超高清", "4K")
    n = re.sub(r"(高清|标清|HD)$", "", n)
    n = re.sub(r"^(CCTV\d+)加$", r"\1+", n)
    n = re.sub(
        r"^(CCTV\d+)(?!\+)(?:综合|财经|综艺|国际|体育|电影|国防军事|电视剧|纪录片|科教|科学教育|戏曲|社会与法|新闻|少儿|音乐|农业农村)$",
        r"\1",
        n,
    )
    n = re.sub(r"^CHC(动作电影|家庭影院|影迷电影)$", r"\1", n)
    n = re.sub(r"^CGTN阿拉伯语$", "CGTN阿语", n)
    n = re.sub(r"^CGTN西班牙语?$", "CGTN西语", n)
    n = n.replace("与", "")
    n = re.sub(r"^朔州电视台(\d+)$", r"朔州\1", n)
    n = re.sub(r"(电视台|频道|台)$", "", n)
    return _CHANNEL_ALIASES.get(n, _CHANNEL_ALIASES.get(n + "台", n))


def _strip_catchup_attrs(extinf: str) -> str:
    return re.sub(r'\s+catchup(?:-[a-z]+)?="[^"]*"', "", extinf)


def _load_json_with_age(path: str) -> tuple:
    """加载 JSON 并返回 (数据, 修改时间字符串, 距今小时数)。"""
    mtime = os.path.getmtime(path)
    age_h = max(0.0, (time.time() - mtime) / 3600.0)
    ts_str = datetime.datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f), ts_str, age_h


def _load_live_index(live_json_path: str, stage_tag: str, always_log: bool = True) -> tuple:
    """加载 -l 直播测活缓存并生成索引，按需输出文件时效与 >24h 过期提醒。"""
    if not live_json_path or not os.path.exists(live_json_path):
        return [], {}, {}, False
    live_list, live_ts, live_age_h = _load_json_with_age(live_json_path)
    fname = os.path.basename(live_json_path)
    if always_log:
        print(f"{stage_tag} 已加载测活缓存 {fname}（生成于 {live_ts}，距今 {live_age_h:.1f} 小时）")
    if live_age_h > 24.0:
        print(f"  ⚠️ 提醒：{fname} 生成于 {live_ts}（已超 24 小时），直播源可用性可能已变化，建议先运行 python3 build_m3u.py -l 刷新！")
    by_idx_url = {(x["idx"], x["play_url"]): x for x in live_list if "idx" in x}
    by_url = {x["play_url"]: x for x in live_list}
    return live_list, by_idx_url, by_url, True


def _insert_attrs(extinf: str, attrs: str) -> str:
    q = extinf.rfind('"')
    idx = extinf.find(",", q) if q >= 0 else -1
    if idx < 0:
        idx = extinf.rfind(",")
    return extinf[:idx] + attrs + extinf[idx:] if idx >= 0 else extinf


def _read_blueprint(atv_m3u_path: str) -> list:
    """只读解析蓝本 atv.m3u 全部频道入口。"""
    with open(atv_m3u_path, "r", encoding="utf-8-sig", errors="ignore") as f:
        lines = [l.rstrip("\r\n") for l in f if l.strip()]
    entries = []
    i = 1
    while i < len(lines):
        line = lines[i]
        if line.startswith("#EXTINF:") and i + 1 < len(lines):
            extinf = _strip_catchup_attrs(line)
            play_url = re.sub(r"[?&](?:playseek|Playseek|r2h-seek-mode|r2h-seek-name)=[^&]*", "", lines[i + 1].strip(), flags=re.I)
            m_tvg = re.search(r'tvg-name="([^"]*)"', extinf)
            m_grp = re.search(r'group-title="([^"]*)"', extinf)
            m_mcast = re.search(r"(\d+\.\d+\.\d+\.\d+:\d+)$", play_url)
            grp = m_grp.group(1).strip() if m_grp else "其他"
            title = extinf.split(",")[-1].strip()
            entries.append({
                "idx": len(entries),
                "title": title,
                "tvg_name": m_tvg.group(1).strip() if m_tvg else title,
                "group": grp,
                "extinf": extinf,
                "play_url": play_url,
                "mcast": m_mcast.group(1) if m_mcast else "",
                "is_4k": grp == "4K超高清" or "4K" in _norm_4k(title),
            })
            i += 2
        else:
            i += 1
    return entries


def _build_catchup_source(raw_rtsp: str, proxy_prefix: str) -> str:
    """清理局端 RTSP 链接冗余参数并组装标准 rtp2httpd 回看模板。"""
    u = raw_rtsp.split("|")[0].strip()
    if not u.lower().startswith("rtsp://"):
        return ""
    u = re.sub(
        r"[?&](?:playseek|playseek-starttime|playseek-endtime|r2h-seek-mode|r2h-seek-name)=[^&]*",
        "",
        u,
        flags=re.I,
    )
    u = re.sub(r"[?&]+$", "", u)
    u = proxy_prefix.rstrip("/") + "/rtsp/" + u[len("rtsp://"):]
    sep = "&" if "?" in u else "?"
    return f"{u}{sep}Playseek=${{(b)yyyyMMddHHmmss:utc}}-${{(e)yyyyMMddHHmmss:utc}}&r2h-seek-mode=range(UTC/10800)"


def _align_blueprint_with_pcap(entries: list, pcap_channels: dict, proxy_prefix: str) -> dict:
    """把蓝本条目与解包后的局端全表对账，过滤同频道异流并输出真新台、改台及候选清单。"""
    mcast_info = pcap_channels["mcast_info"]
    k4_map = pcap_channels["k4_map"]
    all_ch = pcap_channels["all_channels"]

    matched_entries, candidates = [], []
    major_renames, minor_renames, unmatched_mcast, k4_matched_notes = [], [], [], []
    matched_mcasts = set()
    blueprint_canons = {_canon_channel_name(rec["title"]) for rec in entries}

    for rec in entries:
        info = mcast_info.get(rec["mcast"]) if rec["mcast"] else None
        matched_by_4k_name = False
        if not info and rec["is_4k"]:
            info = k4_map.get(_norm_4k(rec["title"]))
            matched_by_4k_name = bool(info)

        if info:
            if info["mcast"]:
                matched_mcasts.add(info["mcast"])
            if matched_by_4k_name:
                src_type = "TimeShiftURL" if info["ts_url"] else "仅ChannelSDP"
                k4_matched_notes.append(f"{rec['title']} (蓝本 {rec['mcast']} ↔ 局端 {info['name']} {info['mcast']}, {src_type})")
            elif info["name"]:
                a = re.sub(r"\s", "", rec["title"]).upper()
                b = re.sub(r"\s", "", info["name"]).upper()
                if a != b:
                    if _canon_channel_name(rec["title"]) != _canon_channel_name(info["name"]):
                        major_renames.append(f"{rec['title']} ({rec['mcast']}) -> 局端已变为 [{info['name']}]")
                    elif a not in b and b not in a:
                        minor_renames.append(f"{rec['title']} ({rec['mcast']}) -> 局端名 [{info['name']}]")
        elif rec["mcast"]:
            unmatched_mcast.append(f"{rec['title']} ({rec['mcast']})")

        raw_rtsp = ""
        if info:
            raw_rtsp = info["ts_url"] or (info["sdp_rtsp"] if rec["is_4k"] else "")
        candidate_tpl = _build_catchup_source(raw_rtsp, proxy_prefix) if raw_rtsp else ""

        enriched = {
            **rec,
            "pcap_name": info["name"] if info else "",
            "has_ts_url": bool(info and info["ts_url"]),
            "has_sdp_rtsp": bool(info and info["sdp_rtsp"]),
            "candidate_tpl": candidate_tpl,
        }
        matched_entries.append(enriched)
        if candidate_tpl:
            candidates.append(enriched)

    # 对局端未直接命中蓝本组播的频道，按归一化名称过滤掉“同台不同视频流/标清备流”
    brand_new_channels, duplicate_streams = [], []
    base_proxy = proxy_prefix.rstrip("/")
    for c in all_ch:
        if not c["mcast"] or c["mcast"] in matched_mcasts:
            continue
        cn = _canon_channel_name(c["name"])
        if cn in blueprint_canons:
            duplicate_streams.append(c)
        else:
            brand_new_channels.append({
                "name": c["name"],
                "mcast": c["mcast"],
                "udp_url": f"{base_proxy}/udp/{c['mcast']}",
                "has_ts": bool(c["ts_url"]),
                "has_sdp": bool(c["sdp_rtsp"]),
            })

    return {
        "entries": matched_entries,
        "candidates": candidates,
        "major_renames": major_renames,
        "minor_renames": minor_renames,
        "unmatched_mcast": unmatched_mcast,
        "k4_matched_notes": k4_matched_notes,
        "brand_new_channels": brand_new_channels,
        "duplicate_streams": duplicate_streams,
    }


def step_unpack(pcap_path: str, blueprint_path: str, pcap_json_path: str, diff_md_path: str, proxy_prefix: str) -> dict:
    """阶段1：读取抓包文件解包，对比 atv.m3u 与局端提取清单（过滤同台异流）并输出详尽说明。"""
    raw_frameset = None
    total_streams = 0
    for s in _extract_tcp_streams(pcap_path):
        total_streams += 1
        raw_frameset = _decode_frameset(s)
        if raw_frameset:
            break
    if not raw_frameset:
        raise RuntimeError("抓包中未找到 frameset_builder.jsp，请确认抓包时已进入机顶盒直播界面！")

    html_txt, enc = _smart_decode(raw_frameset)
    mcast_info, k4_map, all_channels = {}, {}, []

    for m in re.finditer(r"jsSetConfig\('Channel','(.*?)'\);", html_txt, re.S):
        kv = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
        cname = kv.get("ChannelName", "").strip()
        m_url = re.search(r"igmp://(\d+\.\d+\.\d+\.\d+:\d+)", kv.get("ChannelURL", ""))
        ts_url = kv.get("TimeShiftURL", "").strip()
        m_sdp = re.search(r"\|(rtsp://[^\"|]+)", kv.get("ChannelSDP", ""))
        mcast = m_url.group(1) if m_url else ""
        sdp_rtsp = m_sdp.group(1) if m_sdp else ""
        entry = {"name": cname, "mcast": mcast, "ts_url": ts_url, "sdp_rtsp": sdp_rtsp}
        all_channels.append(entry)
        if mcast:
            mcast_info[mcast] = entry
        if "4K" in _norm_4k(cname) and (ts_url or sdp_rtsp):
            k4_map[_norm_4k(cname)] = entry

    pcap_data = {
        "total_streams": total_streams,
        "encoding": enc,
        "all_channels": all_channels,
        "mcast_info": mcast_info,
        "k4_map": k4_map,
    }
    with open(pcap_json_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(pcap_data, f, ensure_ascii=False, indent=2)

    entries = _read_blueprint(blueprint_path)
    aligned = _align_blueprint_with_pcap(entries, pcap_data, proxy_prefix)
    cnt_ext = sum(1 for r in entries if not r["mcast"])
    cnt_mcast = len(entries) - cnt_ext
    cnt_ts = sum(1 for r in aligned["entries"] if r["has_ts_url"])
    cnt_sdp_only = sum(1 for r in aligned["entries"] if not r["has_ts_url"] and r["candidate_tpl"])
    cnt_cand = len(aligned["candidates"])
    new_chs = aligned["brand_new_channels"]
    dup_chs = aligned["duplicate_streams"]
    major_ren = aligned["major_renames"]
    minor_ren = aligned["minor_renames"]
    unmatched = aligned["unmatched_mcast"]
    k4_notes = aligned["k4_matched_notes"]

    diff_lines = [
        "# 阶段 1：抓包解包与蓝本 `atv.m3u` 对账详细说明",
        "",
        f"- **抓包全表**：扫描 {total_streams} 条 TCP 流（编码 `{enc}`），提取局端频道 **{len(all_channels)}** 个（含 `TimeShiftURL` {sum(1 for c in all_channels if c['ts_url'])} 个）。",
        f"- **蓝本对齐**：`atv.m3u` 共 **{len(entries)}** 条（内网组播 {cnt_mcast} 条 + 外网源 {cnt_ext} 条）；已提取待测 RTSP 候选 **{cnt_cand}** 条（原生 `TimeShiftURL` {cnt_ts} 条 + 4K `ChannelSDP` 尝试 {cnt_sdp_only} 条），无单播直转纯直播 **{len(entries) - cnt_cand}** 条。",
        f"- **去重统计**：抓包内另有 **{len(dup_chs)}** 条已自动忽略（属于蓝本已有频道的标清流或备用视频流）。",
        "",
        f"## 1. 局端全新频道清单（蓝本未收录且非同台异流，共 {len(new_chs)} 条，可供测试）",
        "",
    ]
    if new_chs:
        diff_lines.append("| 局端频道名 | 组播地址 | `TimeShiftURL` | `ChannelSDP` | 可直接测试的组播播放地址 |")
        diff_lines.append("| :--- | :--- | :---: | :---: | :--- |")
        for nc in new_chs:
            diff_lines.append(
                f"| **{nc['name']}** | `{nc['mcast']}` | {'有' if nc['has_ts'] else '无'} | {'有' if nc['has_sdp'] else '无'} | `{nc['udp_url']}` |"
            )
        diff_lines.extend(["", "可直接复制到 M3U 试播的条目：", "```m3u"])
        for nc in new_chs:
            diff_lines.append(f'#EXTINF:-1 tvg-name="{nc["name"]}" group-title="待测试",{nc["name"]}')
            diff_lines.append(nc["udp_url"])
        diff_lines.extend(["```", ""])
    else:
        diff_lines.extend(["无全新频道（蓝本已覆盖全部局端不重复频道）。", ""])

    diff_lines.append(f"## 2. 疑似换台 / 实质改名预警（同组播 IP 下台名大幅变化，共 {len(major_ren)} 条，建议试播核实）")
    diff_lines.extend([f"- {w}" for w in major_ren] if major_ren else ["- 无"])
    diff_lines.append("")

    diff_lines.append(f"## 3. 蓝本无局端单播匹配的组播条目（共 {len(unmatched)} 条，保持纯直播）")
    diff_lines.extend([f"- {u}" for u in unmatched] if unmatched else ["- 无"])
    diff_lines.append("")

    if k4_notes:
        diff_lines.append(f"## 4. 4K 超高清跨组播段映射说明（共 {len(k4_notes)} 条）")
        diff_lines.extend([f"- {k}" for k in k4_notes])
        diff_lines.append("")

    if minor_ren:
        diff_lines.append(f"## 5. 仅高清/简称前缀差异（同台未换内容，共 {len(minor_ren)} 条）")
        diff_lines.extend([f"- {w}" for w in minor_ren])
        diff_lines.append("")

    if dup_chs:
        diff_lines.append(f"## 6. 已自动忽略的同频道其他码率/标清流（共 {len(dup_chs)} 条）")
        diff_lines.append("- " + "、".join(f"{c['name']} ({c['mcast']})" for c in dup_chs))
        diff_lines.append("")

    with open(diff_md_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(diff_lines) + "\n")

    print(f"[1/4 解包对账] 抓包全表 {len(all_channels)} 台 | 蓝本 {len(entries)} 条 | 待测 RTSP 候选 {cnt_cand} 条 | 已忽略同台低清/备流 {len(dup_chs)} 条")
    print(f"  ├─ 【发现全新频道 ({len(new_chs)} 条，已剔除同台异流，可供测试)】:")
    if new_chs:
        for nc in new_chs:
            ts_tag = "含回看源" if nc["has_ts"] else "仅直播组播"
            print(f"  │    • {nc['name']:<10s} [{ts_tag}] -> {nc['udp_url']}")
    else:
        print("  │    • 无新增频道")
    if major_ren:
        print(f"  ├─ 【疑似换台/实质更名 ({len(major_ren)} 条，请确认画面)】:")
        for w in major_ren:
            print(f"  │    ! {w}")
    if unmatched:
        print(f"  ├─ 【蓝本未匹配到局端单播 ({len(unmatched)} 条)】: {', '.join(unmatched)}")
    print(f"  └─ 完整对比明细 -> {diff_md_path} | 局端全表 -> {pcap_json_path}")
    return pcap_data


def _is_mpeg_ts(chunk: bytes) -> bool:
    """校验标准 MPEG-TS 连续 188 字节同步字节 (0x47)，避免单字节偶发误判。"""
    n = len(chunk)
    if n >= 377:
        limit = min(n - 376, 512)
        return any(chunk[i] == 0x47 and chunk[i + 188] == 0x47 and chunk[i + 376] == 0x47 for i in range(limit))
    if n >= 189:
        limit = min(n - 188, 188)
        return any(chunk[i] == 0x47 and chunk[i + 188] == 0x47 for i in range(limit))
    return False


def _probe_single_live_stream(play_url: str, timeout: float = 4.0) -> dict:
    """探测单条直播流（支持 udp/ MPEG-TS 与外网 HLS m3u8），校验有效媒体数据。"""
    probe_url = re.sub(r"\?\$[^\s]*$", "", play_url.strip())
    last_detail = "ERR"
    t_start = time.perf_counter()

    for attempt in range(2):
        t0 = time.perf_counter()
        req = urllib.request.Request(probe_url, headers={"Connection": "close", "User-Agent": "Mozilla/5.0"})
        try:
            with _DIRECT_OPENER.open(req, timeout=timeout) as resp:
                chunk = resp.read(4096)
                ms = round((time.perf_counter() - t0) * 1000)
                head = chunk.lstrip().lower()
                if b"#EXTM3U" in chunk:
                    return {"ok": True, "status": str(resp.status), "kind": "M3U8", "ms": ms, "detail": f"HTTP {resp.status} ({ms}ms, M3U8)"}
                if _is_mpeg_ts(chunk):
                    return {"ok": True, "status": str(resp.status), "kind": "TS", "ms": ms, "detail": f"HTTP {resp.status} ({ms}ms, TS)"}
                if len(chunk) >= 64 and not head.startswith((b"<html", b"<!doctype", b"<xml", b"<?xml", b"{")):
                    return {"ok": True, "status": str(resp.status), "kind": "DATA", "ms": ms, "detail": f"HTTP {resp.status} ({ms}ms, {len(chunk)}B)"}
                last_detail = f"HTTP {resp.status} (空流/非媒体响应, {len(chunk)}B)"
        except urllib.error.HTTPError as he:
            last_detail = f"HTTP {he.code}"
        except Exception as exc:
            last_detail = f"ERR:{type(exc).__name__}"

        if attempt == 0:
            time.sleep(0.4)

    return {"ok": False, "status": "FAIL", "kind": "-", "ms": round((time.perf_counter() - t_start) * 1000), "detail": last_detail}


def step_live(
    blueprint_path: str,
    live_json_path: str,
    proxy_prefix: str,
    timeout: float = 4.0,
    cooldown: float = 0.15,
) -> list:
    """阶段2：纯直播测活——逐条探测蓝本 atv.m3u 直播流可用性，仅输出异常警示与结果 JSON（不做交互删减）。"""
    entries = _read_blueprint(blueprint_path)
    base_proxy = proxy_prefix.rstrip("/")
    results = []
    dead_pairs = []

    print(f"[2/4 直播测活] 开始逐条测试蓝本 {len(entries)} 条直播源（单线顺序 + {cooldown:.2f}s IGMP 冷却）...")
    t0 = time.time()
    for pos, rec in enumerate(entries, 1):
        url = rec["play_url"]
        is_lan = url.startswith(base_proxy) or bool(rec["mcast"])
        res = _probe_single_live_stream(url, timeout=timeout)
        item = {
            "idx": rec["idx"],
            "title": rec["title"],
            "group": rec["group"],
            "play_url": url,
            "mcast": rec["mcast"],
            "is_lan": is_lan,
            **res,
        }
        results.append(item)
        if not res["ok"]:
            dead_pairs.append((rec, res["detail"]))
            print(f"  ! [{pos:>3d}/{len(entries)}] [{rec['group']}] {rec['title']:<12s} 失败 -> {res['detail']} | {url}")
        if is_lan:
            time.sleep(cooldown)

    ok_cnt = len(results) - len(dead_pairs)
    print(f"[2/4 直播测活] 完成，耗时 {time.time() - t0:.1f} 秒 | 可用: {ok_cnt} 条 | 超时/失效: {len(dead_pairs)} 条")
    if dead_pairs:
        print(f"⚠️ 检测到 {len(dead_pairs)} 条直播源超时/失效（-l 仅告警，替代检索与去留决策将在 -p 进行）：")
        for n, (rec, detail) in enumerate(dead_pairs, 1):
            print(f"  [{n}] [{rec['group']}] {rec['title']:<12s} | {detail} | {rec['play_url']}")
        print("  -> 下一步请运行 python3 build_m3u.py -p（或 --on-dead auto/drop/keep）排查抓包替代源并测试回看。")

    with open(live_json_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"  └─ 已保存直播测活结果 -> {live_json_path}")
    return results


def _probe_http_offset(url_tpl: str, now_utc: datetime.datetime, mins_ago: int, timeout: float = 6.0) -> str:
    """向 rtp2httpd 发起单点时间窗口 RTSP 握手测试，收到状态码即关闭连接。"""
    b = (now_utc - datetime.timedelta(minutes=mins_ago)).strftime("%Y%m%d%H%M%S")
    e = (now_utc - datetime.timedelta(minutes=mins_ago - 5)).strftime("%Y%m%d%H%M%S")
    u = url_tpl.replace("${(b)yyyyMMddHHmmss:utc}", b).replace("${(e)yyyyMMddHHmmss:utc}", e)

    for attempt in range(2):
        req = urllib.request.Request(u, headers={"Connection": "close", "User-Agent": "Mozilla/5.0"})
        try:
            with _DIRECT_OPENER.open(req, timeout=timeout) as resp:
                return str(resp.status)
        except urllib.error.HTTPError as he:
            if attempt == 0 and he.code in (500, 502, 503, 504):
                time.sleep(0.35)
                continue
            return str(he.code)
        except Exception as exc:
            if attempt == 0:
                time.sleep(0.35)
            else:
                return f"ERR:{type(exc).__name__}"
        finally:
            time.sleep(0.08)
    return "ERR"


def _probe_single_channel(item: dict) -> dict:
    """分级探测单个候选频道（-48h 测7天回看；未过再测 -90m/-210m 区分 4h/3h 时移或死链）。"""
    tpl = item["candidate_tpl"]
    now_utc = datetime.datetime.now(datetime.timezone.utc)
    s48 = _probe_http_offset(tpl, now_utc, 48 * 60)
    if s48 == "200":
        return {"capability": "7d_catchup", "label": "7天回看", "catchup_days": 7, "probe_detail": "48h=200"}

    s90 = _probe_http_offset(tpl, now_utc, 90)
    if s90 == "200":
        s210 = _probe_http_offset(tpl, now_utc, 210)
        if s210 == "200":
            return {"capability": "4h_timeshift", "label": "仅4h时移", "catchup_days": 1, "probe_detail": f"48h={s48},90m=200,210m=200"}
        return {"capability": "3h_timeshift", "label": "仅3h时移", "catchup_days": 1, "probe_detail": f"48h={s48},90m=200,210m={s210}"}

    return {"capability": "dead_unicast", "label": "纯直播(单播不可用)", "catchup_days": 0, "probe_detail": f"48h={s48},90m={s90}"}


def _match_live_record(rec: dict, live_by_idx_url: dict, live_by_url: dict):
    """将蓝本条目精确对齐到 -l 直播测活记录。"""
    return live_by_idx_url.get((rec["idx"], rec["play_url"])) or live_by_url.get(rec["play_url"])


def _find_dead_alternatives(
    dead_records: list,
    live_list: list,
    pcap_data: dict,
    proxy_prefix: str,
    timeout: float = 4.0,
) -> dict:
    """为 -l 中测活失败的条目从抓包数据包与蓝本检索并实测可用替代源（区分抓包组播/单播急救/蓝本已有入口）。"""
    if not dead_records:
        return {}

    base_proxy = proxy_prefix.rstrip("/")
    live_by_url = {x["play_url"]: x for x in live_list}
    by_canon = {}
    for ch in pcap_data.get("all_channels", []):
        if ch.get("mcast"):
            by_canon.setdefault(_canon_channel_name(ch["name"]), []).append(ch)
    mcast_info = pcap_data.get("mcast_info", {})

    probe_cache = {}

    def _cached_live_probe(test_url: str, is_lan: bool) -> dict:
        if test_url not in probe_cache:
            probe_cache[test_url] = _probe_single_live_stream(test_url, timeout=timeout)
            if is_lan:
                time.sleep(0.15)
        return probe_cache[test_url]

    alt_map = {}
    print(f"\n[3/4 失效替代排查] 正在从抓包数据与蓝本为 {len(dead_records)} 条 -l 失效源检索可用替代...")
    for rec, lv in dead_records:
        title = rec["title"]
        url = rec["play_url"]
        mcast = rec.get("mcast", "")
        alts = []
        seen_alt_urls = {url}

        # 1. 抓包内同规范化名称的其他组播流（如标清备流/另一段组播）并现场测活
        cn = _canon_channel_name(title)
        for cand in by_canon.get(cn, []):
            if cand["mcast"] and cand["mcast"] != mcast:
                alt_u = f"{base_proxy}/udp/{cand['mcast']}"
                if alt_u in seen_alt_urls:
                    continue
                known_lv = live_by_url.get(alt_u)
                if known_lv and not known_lv.get("ok"):
                    continue
                res = known_lv if known_lv else _cached_live_probe(alt_u, is_lan=True)
                if res["ok"]:
                    seen_alt_urls.add(alt_u)
                    ts_tag = "含TimeShiftURL" if cand.get("ts_url") else "仅组播"
                    alts.append({
                        "kind": "pcap_mcast",
                        "kind_label": f"抓包同台组播·{ts_tag}",
                        "name": cand["name"],
                        "url": alt_u,
                        "mcast": cand["mcast"],
                        "ts_url": cand.get("ts_url", ""),
                        "sdp_rtsp": cand.get("sdp_rtsp", ""),
                        "detail": res["detail"],
                        "note": f"[抓包组播:{cand['name']}] {alt_u} ({res['detail']}, {ts_tag})",
                    })

        # 2. 若原组播失效，尝试抓包同条目 ChannelSDP 单播直播能否急救
        info = mcast_info.get(mcast) if mcast else None
        if info and info.get("sdp_rtsp") and info["sdp_rtsp"].lower().startswith("rtsp://"):
            rtsp_u = f"{base_proxy}/rtsp/{info['sdp_rtsp'][7:]}"
            if rtsp_u not in seen_alt_urls:
                res = _cached_live_probe(rtsp_u, is_lan=True)
                if res["ok"]:
                    seen_alt_urls.add(rtsp_u)
                    alts.append({
                        "kind": "pcap_rtsp",
                        "kind_label": "抓包单播急救·占1路并发/无回看",
                        "name": info.get("name", title),
                        "url": rtsp_u,
                        "mcast": "",
                        "ts_url": "",
                        "sdp_rtsp": info["sdp_rtsp"],
                        "detail": res["detail"],
                        "note": f"[抓包单播急救] {rtsp_u} ({res['detail']}, 注意占用局端单播并发且无回看)",
                    })

        # 3. 同蓝本内其他已测可用的同名备用入口（如外网多线路冗余死链）
        for x in live_list:
            if x.get("ok") and x["title"] == title and x["play_url"] not in seen_alt_urls:
                seen_alt_urls.add(x["play_url"])
                alts.append({
                    "kind": "m3u_backup",
                    "kind_label": "蓝本已有同台可用入口·建议直接删减此死链",
                    "name": x["title"],
                    "url": x["play_url"],
                    "mcast": x.get("mcast", ""),
                    "ts_url": "",
                    "sdp_rtsp": "",
                    "detail": x["detail"],
                    "note": f"[蓝本已有可用入口] {x['play_url']} ({x['detail']})",
                })

        alt_map[rec["idx"]] = alts
        if alts:
            print(f"  ├─ [{rec['group']}] {title} ({lv['detail']}) -> ✔ 找到替代 ({len(alts)} 条):")
            for a_i, alt in enumerate(alts, 1):
                print(f"  │    ({a_i}) {alt['note']}")
        else:
            print(f"  ├─ [{rec['group']}] {title} ({lv['detail']}) -> ✘ 无可用替代源（抓包与蓝本均未找到替换流）")

    return alt_map


def _pick_auto_decision(alts: list) -> tuple:
    """智能默认策略：有抓包组播/单播急救则自动替换；仅蓝本已有同台备线或无替代则删减死链。"""
    for kind in ("pcap_mcast", "pcap_rtsp"):
        for alt in alts:
            if alt["kind"] == kind:
                return "replace", alt
    return "drop", None


def _prompt_single_dead_decision(pos: int, total: int, rec: dict, lv: dict, alts: list) -> tuple:
    """对单条失效直播源交互询问：有替代提供替换/删减/保留，无替代提供删减/保留。"""
    if alts:
        print(f"\n  ({pos}/{total}) [{rec['group']}] {rec['title']} | 原地址失效: {lv['detail']} | {rec['play_url']}")
        for a_i, alt in enumerate(alts, 1):
            print(f"      ({a_i}) {alt['note']}")
        while True:
            ans = input("    请选择 [r=替换为(1) / rN=替换为第N个 / d=删减 / k=保留，默认 k]: ").strip().lower()
            if ans in ("", "k"):
                return "keep", None
            if ans == "d":
                return "drop", None
            if ans == "r":
                return "replace", alts[0]
            if ans.startswith("r") and ans[1:].isdigit():
                pick = int(ans[1:])
                if 1 <= pick <= len(alts):
                    return "replace", alts[pick - 1]
            print("    输入无效，请输入 r / r1.. / d / k（直接回车保留）。")
    else:
        print(f"\n  ({pos}/{total}) [{rec['group']}] {rec['title']} | 原地址失效: {lv['detail']} | {rec['play_url']}")
        print("      （抓包与蓝本均无可用替代源）")
        while True:
            ans = input("    请选择 [d=删减 / k=保留，默认 k]: ").strip().lower()
            if ans in ("", "k"):
                return "keep", None
            if ans == "d":
                return "drop", None
            print("    输入无效，请输入 d 或 k（直接回车保留）。")


def _decide_dead_actions(dead_records: list, alt_map: dict, on_dead: str) -> dict:
    """根据排查结果对 -l 失效条目做最终去留/替换决策（ask / keep / drop / auto）。"""
    if not dead_records:
        return {}

    has_alt = [(rec, lv, alt_map.get(rec["idx"], [])) for rec, lv in dead_records if alt_map.get(rec["idx"])]
    no_alt = [(rec, lv, []) for rec, lv in dead_records if not alt_map.get(rec["idx"])]
    print(f"\n[3/4 失效源决策] 汇总：有替代方案 {len(has_alt)} 条 | 无可用替代 {len(no_alt)} 条（策略: {on_dead}）")

    decisions = {}
    if on_dead == "keep":
        for rec, _ in dead_records:
            decisions[rec["idx"]] = {"action": "keep", "chosen_alt": None}
        print("  -> 已按 keep 策略全部保留原条目（仅将排查建议写入报告）。")
        return decisions

    if on_dead == "drop":
        for rec, _ in dead_records:
            decisions[rec["idx"]] = {"action": "drop", "chosen_alt": None}
        print(f"  -> 已按 drop 策略全部标记删减（共 {len(dead_records)} 条，跳过 RTSP 回看探测）。")
        return decisions

    if on_dead == "auto":
        for rec, lv in dead_records:
            alts = alt_map.get(rec["idx"], [])
            act, chosen = _pick_auto_decision(alts)
            decisions[rec["idx"]] = {"action": act, "chosen_alt": chosen}
            if act == "replace":
                print(f"  -> [自动替换] [{rec['group']}] {rec['title']} -> {chosen['url']}")
            else:
                reason = "同频道在蓝本已有可用入口" if alts else "抓包与蓝本均无可用替代"
                print(f"  -> [自动删减] [{rec['group']}] {rec['title']}（{reason}）")
        return decisions

    if not sys.stdin or not sys.stdin.isatty():
        for rec, _ in dead_records:
            decisions[rec["idx"]] = {"action": "keep", "chosen_alt": None}
        print("  -> 当前为非交互环境且未指定 auto/drop，默认保留全部原条目；请在终端交互运行 -p，或加 --on-dead auto / drop。")
        return decisions

    print("请选择对上述失效条目的处理方式：")
    print("  [1] 逐条决定（有替代可选 r=替换/d=删减/k=保留；无替代可选 d=删减/k=保留）")
    print("  [2] 一键智能处理（抓包有可用替代自动替换，其余无替代或冗余死链自动删减）")
    print("  [3] 全部保留原条目（继续测试其余配置并在报告保留提示）")
    print("  [4] 全部删减失效条目（跳过回看测试并在 -m 剔除）")
    while True:
        choice = input("请输入选项 [1/2/3/4，默认 1]: ").strip()
        if choice in ("", "1"):
            for pos, (rec, lv) in enumerate(dead_records, 1):
                alts = alt_map.get(rec["idx"], [])
                act, chosen = _prompt_single_dead_decision(pos, len(dead_records), rec, lv, alts)
                decisions[rec["idx"]] = {"action": act, "chosen_alt": chosen}
            return decisions
        if choice == "2":
            for rec, lv in dead_records:
                alts = alt_map.get(rec["idx"], [])
                act, chosen = _pick_auto_decision(alts)
                decisions[rec["idx"]] = {"action": act, "chosen_alt": chosen}
            return decisions
        if choice == "3":
            for rec, _ in dead_records:
                decisions[rec["idx"]] = {"action": "keep", "chosen_alt": None}
            return decisions
        if choice == "4":
            for rec, _ in dead_records:
                decisions[rec["idx"]] = {"action": "drop", "chosen_alt": None}
            return decisions
        print("输入无效，请输入 1、2、3 或 4。")


def step_probe(
    pcap_json_path: str,
    blueprint_path: str,
    verified_json_path: str,
    proxy_prefix: str,
    workers: int,
    live_json_path: str = "",
    on_dead: str = "ask",
) -> list:
    """阶段3：若存在 -l 失效条目先检索抓包/备源替代并按需决策（替换/删减/保留），再探测 RTSP 回看/时移。"""
    if not os.path.exists(pcap_json_path):
        raise FileNotFoundError(f"未找到解包文件 {pcap_json_path}，请先运行: python3 build_m3u.py -u")
    with open(pcap_json_path, "r", encoding="utf-8") as f:
        pcap_data = json.load(f)

    entries = _read_blueprint(blueprint_path)
    aligned = _align_blueprint_with_pcap(entries, pcap_data, proxy_prefix)

    live_list, live_by_idx_url, live_by_url, has_live = _load_live_index(live_json_path, "[3/4 失效替代排查]", always_log=True)
    if not has_live:
        print(f"[3/4 失效替代排查] 提示：未检测到 {live_json_path}，跳过直播失效替代排查（建议先跑 -l）；直接进入 RTSP 回看探测。")

    dead_records = []
    for rec in aligned["entries"]:
        lv = _match_live_record(rec, live_by_idx_url, live_by_url)
        if lv and not lv.get("ok"):
            dead_records.append((rec, lv))

    alt_map = _find_dead_alternatives(dead_records, live_list, pcap_data, proxy_prefix) if dead_records else {}
    decisions = _decide_dead_actions(dead_records, alt_map, on_dead) if dead_records else {}

    # 组织最终 RTSP 探测队列：跳过 drop 条目；若替换为含 TimeShiftURL 的抓包组播，改为测替代流回看
    candidates = []
    cand_tpl_by_idx = {}
    skipped_dropped = 0
    for rec in aligned["entries"]:
        dec = decisions.get(rec["idx"])
        if dec and dec["action"] == "drop":
            skipped_dropped += 1
            continue
        if dec and dec["action"] == "replace":
            alt = dec["chosen_alt"]
            if alt["kind"] == "pcap_mcast":
                raw_rtsp = alt.get("ts_url") or (alt.get("sdp_rtsp") if rec["is_4k"] else "")
                rep_tpl = _build_catchup_source(raw_rtsp, proxy_prefix) if raw_rtsp else ""
                if rep_tpl:
                    candidates.append({**rec, "candidate_tpl": rep_tpl})
                    cand_tpl_by_idx[rec["idx"]] = rep_tpl
            continue
        if rec["candidate_tpl"]:
            candidates.append(rec)
            cand_tpl_by_idx[rec["idx"]] = rec["candidate_tpl"]

    print(f"\n[3/4 回看测活] 开始并发探测 {len(candidates)} 条候选单播（并发={workers}，跳过已删减 {skipped_dropped} 条）...")
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(_probe_single_channel, candidates))
    by_idx = {cand["idx"]: res for cand, res in zip(candidates, results)}

    verified_list = []
    for rec in aligned["entries"]:
        lv = _match_live_record(rec, live_by_idx_url, live_by_url)
        dec = decisions.get(rec["idx"])
        alts = alt_map.get(rec["idx"], [])
        alt_txt = "；".join(a["note"] for a in alts) if alts else ("无可用替代源" if (lv and not lv.get("ok")) else "")
        probe_res = by_idx.get(rec["idx"])

        action = dec["action"] if dec else "keep"
        chosen_alt = dec["chosen_alt"] if dec else None
        final_url = rec["play_url"]
        replace_kind = ""
        catchup_source = ""

        if action == "drop":
            cap, label, cdays, detail = "dropped", "失效已删减", 0, (lv["detail"] if lv else "dead_dropped")
            final_url = ""
        elif action == "replace" and chosen_alt:
            final_url = chosen_alt["url"]
            replace_kind = chosen_alt["kind"]
            if probe_res:
                cap = probe_res["capability"]
                label = f"{probe_res['label']}(已替换)"
                cdays = probe_res["catchup_days"]
                detail = probe_res["probe_detail"]
                catchup_source = cand_tpl_by_idx.get(rec["idx"], "") if cdays > 0 else ""
            else:
                cap = "replaced_live"
                label = f"纯直播(已替换:{chosen_alt['kind_label']})"
                cdays = 0
                detail = f"replaced:{chosen_alt['detail']}"
        elif probe_res:
            cap, label, cdays, detail = probe_res["capability"], probe_res["label"], probe_res["catchup_days"], probe_res["probe_detail"]
            catchup_source = cand_tpl_by_idx.get(rec["idx"], "") if cdays > 0 else ""
        else:
            cap, label, cdays, detail = "live_only", "纯直播(外网/无单播)", 0, "no_rtsp"

        verified_list.append({
            "idx": rec["idx"],
            "key": rec["mcast"] or f"{rec['group']}::{rec['title']}::{rec['idx']}",
            "title": rec["title"],
            "tvg_name": rec["tvg_name"],
            "group": rec["group"],
            "mcast": rec["mcast"],
            "orig_url": rec["play_url"],
            "final_url": final_url,
            "action": action,
            "replace_kind": replace_kind,
            "pcap_name": rec["pcap_name"],
            "is_4k": rec["is_4k"],
            "capability": cap,
            "label": label,
            "catchup_days": cdays,
            "probe_detail": detail,
            "alt_suggestion": alt_txt,
            "catchup_source": catchup_source,
        })

    with open(verified_json_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(verified_list, f, ensure_ascii=False, indent=2)

    cnt_7d = sum(1 for x in verified_list if x["capability"] == "7d_catchup")
    cnt_4h = sum(1 for x in verified_list if x["capability"] == "4h_timeshift")
    cnt_3h = sum(1 for x in verified_list if x["capability"] == "3h_timeshift")
    cnt_rep = sum(1 for x in verified_list if x["action"] == "replace")
    cnt_drp = sum(1 for x in verified_list if x["action"] == "drop")
    cnt_live = len(verified_list) - cnt_7d - cnt_4h - cnt_3h - cnt_drp
    print(f"  ├─ 耗时 {time.time() - t0:.1f} 秒 | 7天回看: {cnt_7d} | 仅4h时移: {cnt_4h} | 仅3h时移: {cnt_3h} | 纯直播: {cnt_live} | 替换: {cnt_rep} | 删减: {cnt_drp}")
    print(f"  └─ 已输出终选待合并清单 -> {verified_json_path}")
    return verified_list


def _export_channels_epg_json(out_lines: list, epg_config_path: str):
    """直接从生成的终版 M3U 行提取脱敏频道配置 JSON（供独立公开 EPG 仓库使用）。"""
    channels = {}
    for line in out_lines:
        if not line.startswith("#EXTINF:"):
            continue
        m_tvg = re.search(r'tvg-name="([^"]*)"', line)
        m_grp = re.search(r'group-title="([^"]*)"', line)
        m_days = re.search(r'catchup-days="([^"]*)"', line)
        tvg_name = m_tvg.group(1).strip() if m_tvg else ""
        group = m_grp.group(1).strip() if m_grp else "其他"
        title = line.split(",")[-1].strip()
        cid = tvg_name or title
        if not cid:
            continue
        has_catchup = "catchup=" in line
        cdays = int(m_days.group(1)) if m_days else (7 if has_catchup else 0)
        if cid not in channels:
            channels[cid] = {"id": cid, "group": group, "titles": [title], "aliases": [cid], "catchup": has_catchup, "cdays": cdays}
        else:
            if has_catchup:
                channels[cid]["catchup"] = True
            if cdays > channels[cid]["cdays"]:
                channels[cid]["cdays"] = cdays
            if title not in channels[cid]["titles"]:
                channels[cid]["titles"].append(title)
        if title and title not in channels[cid]["aliases"]:
            channels[cid]["aliases"].append(title)

    parent = os.path.dirname(os.path.abspath(epg_config_path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(epg_config_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(list(channels.values()), f, ensure_ascii=False, indent=2)


def step_merge(
    blueprint_path: str,
    verified_json_path: str,
    out_m3u_path: str,
    epg_config_path: str,
    report_path: str,
    tvg_url: str,
    live_json_path: str = "",
):
    """阶段4：纯离线确定性合并，按 verified_sources.json 中的替换/删减/回看决策与只读蓝本输出终版 M3U 与脱敏 JSON。"""
    if not os.path.exists(verified_json_path):
        raise FileNotFoundError(f"未找到已测源数据 {verified_json_path}，请先运行: python3 build_m3u.py -p")
    verified_list, ver_ts, ver_age_h = _load_json_with_age(verified_json_path)
    if ver_age_h > 24.0:
        print(f"⚠️ 提醒：{os.path.basename(verified_json_path)} 生成于 {ver_ts}（距今 {ver_age_h:.1f} 小时，已超 24 小时），如需最新状态建议重跑 -l/-p。")

    _, live_by_idx_url, live_by_url, _ = _load_live_index(live_json_path, "[4/4 合并读取]", always_log=False)

    by_idx_url = {(x["idx"], x["orig_url"]): x for x in verified_list if "idx" in x and x.get("orig_url")}
    by_url = {x["orig_url"]: x for x in verified_list if x.get("orig_url")}
    by_exact = {(x.get("mcast", ""), x["group"], x["title"]): x for x in verified_list}
    by_mcast = {x["mcast"]: x for x in verified_list if x.get("mcast")}
    by_gt = {(x["group"], x["title"]): x for x in verified_list}

    entries = _read_blueprint(blueprint_path)
    out_lines = [f'#EXTM3U x-tvg-url="{tvg_url}"']
    report_rows = []
    replaced_rows = []
    dropped_rows = []
    alt_notes = []

    for rec in entries:
        lv = _match_live_record(rec, live_by_idx_url, live_by_url)
        live_txt = lv["detail"] if lv else "未测"

        v = (
            by_idx_url.get((rec["idx"], rec["play_url"]))
            or by_url.get(rec["play_url"])
            or by_exact.get((rec["mcast"], rec["group"], rec["title"]))
            or (by_mcast.get(rec["mcast"]) if rec["mcast"] else None)
            or by_gt.get((rec["group"], rec["title"]))
        )
        alt_txt = v.get("alt_suggestion", "") if v else ""
        action = v.get("action", "keep") if v else "keep"
        if action == "drop" or (lv and lv.get("drop") and action == "keep"):
            dropped_rows.append((rec["idx"] + 1, rec["group"], rec["title"], rec["play_url"], live_txt, alt_txt))
            continue

        out_url = rec["play_url"]
        live_report_txt = live_txt
        if action == "replace" and v and v.get("final_url"):
            out_url = v["final_url"]
            live_report_txt = f"已替换({live_txt} -> 替代可用)"
            replaced_rows.append((len(report_rows) + 1, rec["group"], rec["title"], rec["play_url"], out_url, live_txt, v.get("label", "")))
        elif alt_txt and lv and not lv.get("ok"):
            alt_notes.append((rec["idx"] + 1, rec["group"], rec["title"], live_txt, alt_txt))

        extinf = rec["extinf"]
        final_tvg = rec["tvg_name"]

        label, detail, cdays = "纯直播(无单播)", "no_rtsp", 0
        if v:
            label, cdays, detail = v["label"], v["catchup_days"], v["probe_detail"]
            if cdays > 0 and v.get("catchup_source"):
                attrs = f' catchup="default" catchup-days="{cdays}" catchup-source="{v["catchup_source"]}"'
                extinf = _insert_attrs(extinf, attrs)

        out_lines.append(extinf)
        out_lines.append(out_url)
        report_rows.append((len(report_rows) + 1, rec["group"], rec["title"], final_tvg, live_report_txt, label, cdays, detail))

    with open(out_m3u_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out_lines) + "\n")
    _export_channels_epg_json(out_lines, epg_config_path)

    cnt_7d = sum(1 for x in report_rows if x[6] >= 7)
    cnt_1d = sum(1 for x in report_rows if x[6] == 1)
    cnt_0d = len(report_rows) - cnt_7d - cnt_1d
    md_lines = [
        "# 山西联通 IPTV M3U 实机测活与合并结果",
        "",
        f"- **最终输出频道入口**：{len(report_rows)} 条（7天回看: **{cnt_7d}** | 仅3~4h时移: **{cnt_1d}** | 纯直播: **{cnt_0d}** | 已替换失效源: **{len(replaced_rows)}** 条 | 已剔除失效源: **{len(dropped_rows)}** 条）",
        "",
        "| # | 分组 | 频道名 | `tvg-name` | 直播状态 | 回看/时移结论 | `catchup-days` | 探针详情 |",
        "| :---: | :--- | :--- | :--- | :--- | :---: | :---: | :--- |",
    ]
    for i, grp, title, tvg, live_txt, label, cdays, detail in report_rows:
        md_lines.append(f"| {i} | {grp} | {title} | `{tvg}` | {live_txt} | **{label}** | `{cdays}` | `{detail}` |")
    if replaced_rows:
        md_lines.extend(["", "## 已替换为可用替代源的频道", ""])
        for i, grp, title, orig_u, new_u, live_txt, label in replaced_rows:
            md_lines.append(f"- 终版第 {i} 条 [{grp}] {title}（原 `{orig_u}` {live_txt}）-> 替换为 `{new_u}`（{label}）")
    if alt_notes:
        md_lines.extend(["", "## 保留失效频道及替代源排查提示", ""])
        for i, grp, title, live_txt, alt_txt in alt_notes:
            md_lines.append(f"- 原第 {i} 条 [{grp}] {title} ({live_txt}) -> {alt_txt}")
    if dropped_rows:
        md_lines.extend(["", "## 已按需剔除的直播超时/失效条目", ""])
        for i, grp, title, url, live_txt, alt_txt in dropped_rows:
            suffix = f" | 替代排查: {alt_txt}" if alt_txt else ""
            md_lines.append(f"- 原第 {i} 条 [{grp}] {title}: `{url}` ({live_txt}{suffix})")
    with open(report_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(md_lines) + "\n")

    print(f"[4/4 合并完成] 输出={len(report_rows)} 条 (7天回看={cnt_7d} | 仅时移={cnt_1d} | 纯直播={cnt_0d} | 已替换={len(replaced_rows)} | 已删减={len(dropped_rows)})")
    print(f"  ├─ 终版带回看列表 -> {out_m3u_path}")
    print(f"  ├─ 脱敏频道表JSON -> {epg_config_path}（可直接拷入公开 EPG 仓库）")
    print(f"  └─ 实测明细报告   -> {report_path}")
    if "YOUR_PUBLIC_EPG_REPO" in tvg_url or not tvg_url.strip().lower().startswith(("http://", "https://")):
        print(f"  ⚠️ 注意：当前 x-tvg-url 仍为占位或无效地址 ({tvg_url})，正式使用前请通过 -t \"你的真实EPG地址\" 重新运行 -m 替换！")


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    epg_repo_dir = os.path.join(base_dir, "epg_public_repo")
    default_epg_cfg = os.path.join(epg_repo_dir, "channels_epg.json") if os.path.isdir(epg_repo_dir) else os.path.join(base_dir, "channels_epg.json")

    parser = argparse.ArgumentParser(
        description="山西联通 IPTV 本地/LXC 四阶段独立 M3U 构建工具（不带执行参数时默认只打印帮助，不改动任何文件）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "常用示例:\n"
            "  python3 build_m3u.py -e                                       # 一键完整流程 (-u -> -l -> -p -> -m)\n"
            "  python3 build_m3u.py -e --on-dead auto                        # 完整流程：抓包有替代自动替换，无替代或冗余死链自动剔除\n"
            "  python3 build_m3u.py -u                                       # 第1步：解包抓包文件并输出与蓝本对比说明\n"
            "  python3 build_m3u.py -l                                       # 第2步：纯直播测活，输出异常警示与 live_sources.json\n"
            "  python3 build_m3u.py -p                                       # 第3步：排查替代源、决定替换/删减/保留并测试 RTSP 回看/时移\n"
            "  python3 build_m3u.py -m -t \"https://.../epg.xml.gz\"           # 第4步：纯离线合并，输出终版 M3U 与脱敏 JSON\n"
        ),
    )
    parser.add_argument("-e", "--execute", action="store_true", help="一键跑完完整流程 (-u -> -l -> -p -> -m)")
    parser.add_argument("-u", "--unpack", action="store_true", help="阶段1：解包 iptv_sig.pcap 并对比蓝本 atv.m3u 给出差异说明")
    parser.add_argument("-l", "--live", action="store_true", help="阶段2：纯测活蓝本全部直播源并输出超时/失效警告列表")
    parser.add_argument("-p", "--probe", action="store_true", help="阶段3：为 -l 失效台排查抓包/备源替代并按 --on-dead 决策，再探测 RTSP 回看/时移")
    parser.add_argument("-m", "--merge", action="store_true", help="阶段4：纯离线结合已确认结果与只读蓝本输出成品 M3U 与脱敏 JSON")
    parser.add_argument("--pcap", default=os.path.join(base_dir, "iptv_sig.pcap"), help="抓包文件 .pcap 路径")
    parser.add_argument("--blueprint", default=os.path.join(base_dir, "atv.m3u"), help="只读稳定蓝本 atv.m3u 路径")
    parser.add_argument("--pcap-json", default=os.path.join(base_dir, "pcap_channels.json"), help="阶段1解包输出 JSON")
    parser.add_argument("--diff-md", default=os.path.join(base_dir, "unpack_diff.md"), help="阶段1对账说明报告")
    parser.add_argument("--live-json", default=os.path.join(base_dir, "live_sources.json"), help="阶段2直播测活输出 JSON")
    parser.add_argument("--live-timeout", type=float, default=4.0, help="直播单路测活超时秒数（默认 4.0）")
    parser.add_argument("--live-cooldown", type=float, default=0.15, help="组播切台 IGMP 冷却秒数（默认 0.15）")
    parser.add_argument("--on-dead", choices=["ask", "keep", "drop", "auto"], default=None, help="阶段3(-p)失效源决策策略：ask(交互逐条替换/删减/保留)/auto(有抓包替代则换，否则删)/keep(全留)/drop(全删)")
    parser.add_argument("--verified-json", default=os.path.join(base_dir, "verified_sources.json"), help="阶段3实测源清单 JSON")
    parser.add_argument("-o", "--out-m3u", default=os.path.join(base_dir, "atv_catchup.m3u"), help="阶段4输出终版 M3U")
    parser.add_argument("--epg-config", default=default_epg_cfg, help="阶段4导出的脱敏频道表 JSON")
    parser.add_argument("--report", default=os.path.join(base_dir, "m3u_report.md"), help="阶段4合并与测活明细表")
    parser.add_argument("--proxy-prefix", default=DEFAULT_PROXY_PREFIX, help="rtp2httpd 地址前缀")
    parser.add_argument("-t", "--tvg-url", default=DEFAULT_TVG_URL, help="顶部 x-tvg-url 公开 EPG 链接")
    parser.add_argument("-w", "--workers", type=int, default=2, help="RTSP 探测并发数（默认2，适配单进程10连接上限）")
    args = parser.parse_args()

    do_unpack = args.execute or args.unpack
    do_live = args.execute or args.live
    do_probe = args.execute or args.probe
    do_merge = args.execute or args.merge

    if not (do_unpack or do_live or do_probe or do_merge):
        parser.print_help()
        print("\n提示：直接运行不执行任何操作，请加上 -e（完整流程）或 -u / -l / -p / -m 分步执行。")
        return

    if do_unpack:
        step_unpack(args.pcap, args.blueprint, args.pcap_json, args.diff_md, args.proxy_prefix)
    if do_live:
        step_live(args.blueprint, args.live_json, args.proxy_prefix, args.live_timeout, args.live_cooldown)
    if do_probe:
        step_probe(args.pcap_json, args.blueprint, args.verified_json, args.proxy_prefix, args.workers, args.live_json, args.on_dead or "ask")
    if do_merge:
        if args.on_dead and not do_probe:
            print("⚠️ 提示：--on-dead 策略在阶段3 (-p) 决策并写入 verified_sources.json；阶段4 (-m) 只执行纯合并。如需变更决策请加 -p。")
        step_merge(args.blueprint, args.verified_json, args.out_m3u, args.epg_config, args.report, args.tvg_url, args.live_json)


if __name__ == "__main__":
    main()
