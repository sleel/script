#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
山西联通 IPTV 4K 频道测速优选独立工具（脱离主线，不依赖 build_m3u / build_epg）

功能：
  1. 读取当前目录下的成果文件 atv_catchup.m3u（若无则尝试 atv.m3u）与 pcap_channels.json
  2. 提取所有 4K 频道的多路候选组播（蓝本现有流 vs 抓包发现流，可选含 RTSP）
  3. 逐路带间隔直连拉流实测（HTTP 状态、TS 同步、加密位 scr、丢包计数 CC err、首包 TTFB、实测码率 Mbps）
  4. 输出测速报告 4k_benchmark.md，并对存在可用优选对比的频道逐个给出交互式独立选择 [1/2/s]

用法：
  python3 optimize_4k.py                 # 实测全部 4K 候选流并逐频道交互式选择优选结果
  python3 optimize_4k.py --report-only   # 仅测速并生成报告，不修改 M3U
  python3 optimize_4k.py --auto          # 测速后自动采纳每路推荐最优源写入 M3U
  python3 optimize_4k.py --include-rtsp  # 连同抓包里的 RTSP live 流一起加入对比
"""

import argparse
import json
import os
import re
import time
import urllib.request

# 直连内网 rtp2httpd，强制绕过系统/环境代理
_DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _norm_4k(name: str) -> str:
    return name.replace("超高清", "4K").replace(" ", "").upper()


def _detect_proxy_prefix(lines: list) -> str:
    for line in lines:
        m = re.match(r"^(https?://[^/]+)/udp/", line.strip(), re.I)
        if m:
            return m.group(1)
    return "http://10.10.66.1:8009"


def _analyze_ts_packets(buf: bytearray) -> dict:
    """分析 MPEG-TS 包头：检查 0x47 同步、加扰加密标志及 Continuity Counter 连续性丢包。"""
    start = buf.find(b"\x47")
    while start >= 0 and start + 376 < len(buf) and buf[start + 188] != 0x47:
        start = buf.find(b"\x47", start + 1)

    total_pkts, scrambled, cc_err = 0, 0, 0
    last_cc = {}
    if start >= 0:
        pos = start
        end = len(buf)
        while pos + 188 <= end:
            if buf[pos] != 0x47:
                nxt = buf.find(b"\x47", pos)
                if nxt < 0:
                    break
                pos = nxt
                continue
            b1, b2, b3 = buf[pos + 1], buf[pos + 2], buf[pos + 3]
            pid = ((b1 & 0x1F) << 8) | b2
            if pid != 0x1FFF:
                total_pkts += 1
                if (b3 & 0xC0) != 0:
                    scrambled += 1
                has_payload = (b3 & 0x10) != 0
                cc = b3 & 0x0F
                # 遵循 ISO 13818-1：允许单次重复 CC 包，仅在序号跳变时计为丢包
                if has_payload and pid in last_cc and cc not in (last_cc[pid], (last_cc[pid] + 1) & 0x0F):
                    cc_err += 1
                if has_payload:
                    last_cc[pid] = cc
            pos += 188
    return {"pkts": total_pkts, "scrambled": scrambled, "cc_err": cc_err}


def benchmark_stream(url: str, duration: float = 2.2, timeout: float = 4.0) -> dict:
    """对单条流拉取 duration 秒实流并计算可用性、首包耗时、真实码率及 TS 完整性。"""
    t0 = time.perf_counter()
    req = urllib.request.Request(url, headers={"Connection": "close", "User-Agent": "VLC/3.0"})
    try:
        with _DIRECT_OPENER.open(req, timeout=timeout) as resp:
            status = resp.status
            buf = bytearray()
            first_len = 0
            ttfb_ms = None
            t_dl_start = None
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                now = time.perf_counter()
                if ttfb_ms is None:
                    ttfb_ms = (now - t0) * 1000.0
                    t_dl_start = now
                    first_len = len(chunk)
                buf.extend(chunk)
                if now - t_dl_start >= duration:
                    break

            dl_sec = max((time.perf_counter() - (t_dl_start or t0)), 0.001)
            ts_info = _analyze_ts_packets(buf)
            # 稳态码率剔除首包等待延迟（用首包之后拉到的字节数 / 实际持续拉流秒数）
            steady_bytes = max(len(buf) - first_len, len(buf)) if len(buf) <= first_len else (len(buf) - first_len)
            mbps = (steady_bytes * 8.0 / 1_000_000.0) / dl_sec
            usable = status == 200 and ts_info["pkts"] >= 100 and ts_info["scrambled"] == 0
            return {
                "ok": usable,
                "status": str(status),
                "ttfb_ms": round(ttfb_ms or 9999.0, 1),
                "mbps": round(mbps, 2),
                "dl_kb": round(len(buf) / 1024.0, 1),
                "dl_sec": round(dl_sec, 2),
                **ts_info,
                "error": "" if usable else ("加密加扰" if ts_info["scrambled"] > 0 else "无有效TS流"),
            }
    except Exception as exc:
        return {
            "ok": False,
            "status": "ERR",
            "ttfb_ms": 9999.0,
            "mbps": 0.0,
            "dl_kb": 0.0,
            "dl_sec": 0.0,
            "pkts": 0,
            "scrambled": 0,
            "cc_err": 9999,
            "error": type(exc).__name__,
        }


def _score_candidate(res: dict) -> tuple:
    """评分规则：可用且零加扰 -> 丢包越少越好 -> 组播优先(若有同分) -> 码率更高(>=2Mbps差距才优先) -> 首包越快越好。"""
    if not res["ok"]:
        return (0, -99999, 0.0, -99999.0)
    cc_score = -res["cc_err"]
    # 码率按 1.5Mbps 阶梯量化，避免 23.6 vs 23.7 Mbps 随机波动抢走首包快 40ms 的源
    bitrate_tier = round(res["mbps"] / 1.5)
    return (1, cc_score, bitrate_tier, -res["ttfb_ms"])


def _format_metric(res: dict) -> str:
    if not res["ok"]:
        return f"不可用 ({res['status']} {res['error']})"
    return f"正常 | 首包 {res['ttfb_ms']:5.0f}ms | 码率 {res['mbps']:5.2f} Mbps | 丢包 {res['cc_err']} | 包 {res['pkts']}"


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    default_m3u = os.path.join(base_dir, "atv_catchup.m3u")
    if not os.path.exists(default_m3u):
        default_m3u = os.path.join(base_dir, "atv.m3u")

    parser = argparse.ArgumentParser(description="山西联通 IPTV 4K 频道测速优选工具（读取当前目录成果，逐台对比选择）")
    parser.add_argument("-m", "--m3u", default=default_m3u, help="输入 M3U 路径（默认优先 atv_catchup.m3u）")
    parser.add_argument("--pcap-json", default=os.path.join(base_dir, "pcap_channels.json"), help="阶段1解包出的 pcap_channels.json 路径")
    parser.add_argument("-o", "--out", default="", help="保存优选后 M3U 的路径（默认写回输入 M3U）")
    parser.add_argument("--report", default=os.path.join(base_dir, "4k_benchmark.md"), help="测速对比报告路径")
    parser.add_argument("--duration", type=float, default=2.2, help="每路流持续拉流测速秒数（默认 2.2 秒）")
    parser.add_argument("--cooldown", type=float, default=0.6, help="切台换流前 IGMP 退网冷却秒数（默认 0.6 秒，防路由拥塞）")
    parser.add_argument("--include-rtsp", action="store_true", help="将抓包里的 RTSP live 单播也纳入候选对比")
    parser.add_argument("--report-only", action="store_true", help="仅执行测速并生成报告，不交互也不修改 M3U")
    parser.add_argument("--auto", action="store_true", help="不交互询问，自动采用每台推荐最优源")
    args = parser.parse_args()

    if not os.path.exists(args.m3u):
        raise FileNotFoundError(f"当前目录下找不到 M3U 文件: {args.m3u}")

    with open(args.m3u, "r", encoding="utf-8-sig") as f:
        raw_lines = [l.rstrip("\r\n") for l in f if l.strip()]

    pcap_k4 = {}
    if os.path.exists(args.pcap_json):
        with open(args.pcap_json, "r", encoding="utf-8") as f:
            pcap_k4 = json.load(f).get("k4_map", {})

    proxy_prefix = _detect_proxy_prefix(raw_lines)
    k4_items = []
    matched_pcap_keys = set()

    for idx in range(1, len(raw_lines), 2):
        if idx + 1 >= len(raw_lines):
            break
        extinf = raw_lines[idx]
        cur_url = raw_lines[idx + 1].strip()
        if not extinf.startswith("#EXTINF:"):
            continue
        title = extinf.split(",")[-1].strip()
        is_4k = 'group-title="4K超高清"' in extinf or "4K" in _norm_4k(title)
        if not is_4k:
            continue

        cands = [{"tag": "当前M3U源", "url": cur_url, "is_current": True}]
        seen_urls = {cur_url}

        key = _norm_4k(title)
        pc = pcap_k4.get(key)
        if pc:
            matched_pcap_keys.add(key)
            if pc.get("mcast"):
                u_pcap = f"{proxy_prefix}/udp/{pc['mcast']}"
                if u_pcap not in seen_urls:
                    cands.append({"tag": "抓包组播源", "url": u_pcap, "is_current": False})
                    seen_urls.add(u_pcap)
            if args.include_rtsp and pc.get("sdp_rtsp") and pc["sdp_rtsp"].startswith("rtsp://"):
                u_rtsp = f"{proxy_prefix}/rtsp/{pc['sdp_rtsp'][7:]}"
                if u_rtsp not in seen_urls:
                    cands.append({"tag": "抓包RTSP源", "url": u_rtsp, "is_current": False})
                    seen_urls.add(u_rtsp)

        k4_items.append({
            "line_idx": idx + 1,
            "title": title,
            "cur_url": cur_url,
            "candidates": cands,
        })

    if not k4_items:
        print("M3U 中未找到 4K 频道。")
        return

    print(f"已读取 {len(k4_items)} 个 4K 频道，开始逐路冷静测速（每路 {args.duration}s + {args.cooldown}s IGMP 冷却）...\n")

    md_lines = [
        "# 4K 超高清频道多源实测优选报告",
        "",
        "| 频道名 | 来源类型 | 播放地址 | 状态 / TS质量 | 首包耗时 | 实测码率 | 丢包数 | 建议 |",
        "| :--- | :--- | :--- | :--- | :---: | :---: | :---: | :---: |",
    ]

    actionable = []
    for pos, item in enumerate(k4_items, 1):
        print(f"[{pos}/{len(k4_items)}] 正在测试 {item['title']} ...")
        for c in item["candidates"]:
            c["res"] = benchmark_stream(c["url"], duration=args.duration)
            print(f"    {c['tag']} ({c['url']}) -> {_format_metric(c['res'])}")
            time.sleep(args.cooldown)

        best_idx = max(range(len(item["candidates"])), key=lambda k: _score_candidate(item["candidates"][k]["res"]))
        item["best_idx"] = best_idx
        best_c = item["candidates"][best_idx]
        cur_c = item["candidates"][0]

        for k, c in enumerate(item["candidates"]):
            r = c["res"]
            mark = "**★ 推荐**" if (k == best_idx and r["ok"]) else ("当前使用" if c["is_current"] else "-")
            st_txt = f"200 ({r['pkts']}包)" if r["ok"] else f"{r['status']} {r['error']}"
            md_lines.append(
                f"| {item['title']} | {c['tag']} | `{c['url']}` | {st_txt} | "
                f"{r['ttfb_ms']:.0f} ms | {r['mbps']:.2f} Mbps | {r['cc_err']} | {mark} |"
            )

        if len(item["candidates"]) >= 2 and any(c["res"]["ok"] for c in item["candidates"]):
            better_diff = best_idx != 0 and best_c["res"]["ok"]
            actionable.append((item, better_diff))

    extra_4k = [v for k, v in pcap_k4.items() if k not in matched_pcap_keys]
    if extra_4k:
        md_lines.extend(["", "## 抓包内其余未并入蓝本 `4K超高清` 组的频道（仅提示）"])
        for ex in extra_4k:
            md_lines.append(f"- {ex['name']}: `{proxy_prefix}/udp/{ex['mcast']}`")

    with open(args.report, "w", encoding="utf-8", newline="\n") as rf:
        rf.write("\n".join(md_lines) + "\n")
    print(f"\n测速报告已保存 -> {args.report}")

    if args.report_only:
        print("已按 --report-only 模式完成测速，未修改 M3U 文件。")
        return

    if not actionable:
        print("未发现有多路可用对比的 4K 频道，无需修改。")
        return

    replacements = {}
    if args.auto:
        for item, better_diff in actionable:
            if better_diff:
                best_c = item["candidates"][item["best_idx"]]
                replacements[item["line_idx"]] = (item["title"], item["cur_url"], best_c["url"], best_c["tag"])
    else:
        print("\n================ 4K 频道单独优选确认 ================")
        for idx, (item, better_diff) in enumerate(actionable, 1):
            rec_tag = "建议换用推荐源" if better_diff else "当前源已是最优/双源性能相近"
            print(f"\n[{idx}/{len(actionable)}] {item['title']}（{rec_tag}）:")
            for k, c in enumerate(item["candidates"], 1):
                star = "  ★推荐" if (k - 1 == item["best_idx"] and c["res"]["ok"]) else ""
                cur_hint = " (当前)" if c["is_current"] else ""
                print(f"  [{k}] {c['tag']}{cur_hint}: {c['url']}")
                print(f"      {_format_metric(c['res'])}{star}")
            default_choice = item["best_idx"] + 1
            while True:
                ans = input(f"  请选择 (1~{len(item['candidates'])}，直接回车选[{default_choice}]，输 s 保持当前不改): ").strip().lower()
                if ans == "s":
                    break
                if ans == "":
                    pick = default_choice - 1
                elif ans.isdigit() and 1 <= int(ans) <= len(item["candidates"]):
                    pick = int(ans) - 1
                else:
                    print("  输入无效，请重新输入。")
                    continue
                chosen = item["candidates"][pick]
                if chosen["url"] != item["cur_url"]:
                    replacements[item["line_idx"]] = (item["title"], item["cur_url"], chosen["url"], chosen["tag"])
                break

    if not replacements:
        print("\n未做任何 URL 替换，M3U 保持原样。")
        return

    out_path = args.out or args.m3u
    new_lines = list(raw_lines)
    print("\n即将应用以下 4K 频道替换：")
    for line_idx, (title, old_u, new_u, tag) in replacements.items():
        new_lines[line_idx] = new_u
        print(f"  • {title}: {old_u} -> {new_u} ({tag})")

    if not args.auto:
        confirm = input(f"\n确认写入 {out_path}？[Y/n]: ").strip().lower()
        if confirm not in ("", "y", "yes"):
            print("已取消写入，M3U 未改动。")
            return

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(new_lines) + "\n")
    print(f"✅ 已完成 4K 优选并更新写入: {out_path}")


if __name__ == "__main__":
    main()
