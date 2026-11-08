#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_domains.py - 提取浏览器 DevTools (.devtools) / HAR (.har) 网络流量中的访问地址
自动与 config.json 中的现有白名单对比，输出未覆盖的域名以及建议添加到 domain_suffix 的根域名。
"""

import sys
import os
import json
import ipaddress
from urllib.parse import urlparse
from collections import Counter
import argparse

# 确保在 Windows 控制台或管道下 UTF-8 正常输出
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# 常见二级国家/地区顶级域名后缀
MULTI_PART_TLDS = {
    "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
    "com.hk", "org.hk", "edu.hk", "idv.hk",
    "co.uk", "org.uk", "me.uk",
    "com.tw", "org.tw",
    "co.jp", "ne.jp"
}

def is_private_ip(host: str) -> bool:
    try:
        ip = ipaddress.ip_address(host)
        return ip.is_private or ip.is_loopback
    except ValueError:
        return False

def get_base_domain(host: str) -> str:
    """提取建议的 domain_suffix（主域名）"""
    if is_private_ip(host) or host == "localhost":
        return host

    parts = host.lower().split('.')
    if len(parts) <= 2:
        return host

    # 检查是否匹配类似 .com.cn 的复合后缀
    two_level_suffix = ".".join(parts[-2:])
    if two_level_suffix in MULTI_PART_TLDS and len(parts) >= 3:
        return ".".join(parts[-3:])

    return ".".join(parts[-2:])

def load_existing_suffixes(config_path: str):
    """读取 config.json 中的 direct-domains 规则"""
    if not config_path or not os.path.exists(config_path):
        return set()

    suffixes = set()
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        for rs in cfg.get("route", {}).get("rule_set", []):
            if rs.get("tag") == "direct-domains":
                for r in rs.get("rules", []):
                    suffixes.update(r.get("domain_suffix", []))
    except Exception as e:
        print(f"[警告] 读取配置文件 {config_path} 失败: {e}", file=sys.stderr)
    return suffixes

def matches_whitelist(host: str, whitelist: set) -> bool:
    """检查 host 是否已被现有白名单规则覆盖"""
    host_lower = host.lower()
    for item in whitelist:
        item_lower = item.lower()
        if host_lower == item_lower or host_lower.endswith("." + item_lower):
            return True
    return False

def extract_from_file(file_path: str):
    """解析 HAR / DevTools 导出文件"""
    with open(file_path, "r", encoding="utf-8", errors="replace") as f:
        data = json.load(f)

    entries = data.get("log", {}).get("entries", [])
    if not entries and isinstance(data, list):
        entries = data

    host_counts = Counter()
    for entry in entries:
        req = entry.get("request", {})
        url = req.get("url", "")
        if not url:
            continue
        parsed = urlparse(url)
        host = parsed.hostname
        if host:
            host_counts[host.strip()] += 1

    return host_counts, len(entries)

def main():
    parser = argparse.ArgumentParser(
        description="从 DevTools (.devtools) 或 HAR (.har) 流量文件中提取域名地址，并与白名单比对。"
    )
    parser.add_argument("file", help="网络流量文件路径 (例如 download.devtools)")
    parser.add_argument(
        "-c", "--config",
        default="config.json",
        help="sing-box 配置文件路径 (默认当前目录下 config.json)"
    )
    parser.add_argument(
        "-a", "--all",
        action="store_true",
        help="列出所有访问地址（默认仅列出未在白名单中的地址）"
    )

    args = parser.parse_args()

    if not os.path.exists(args.file):
        print(f"错误: 找不到文件 {args.file}")
        sys.exit(1)

    host_counts, total_entries = extract_from_file(args.file)
    whitelist = load_existing_suffixes(args.config)

    print(f"\n" + "=" * 62)
    print(f" 流量文件: {os.path.basename(args.file)}")
    print(f" 总请求数: {total_entries} | 独立主机地址数: {len(host_counts)}")
    if whitelist:
        print(f" 已加载白名单后缀数 ({args.config}): {len(whitelist)}")
    else:
        print(f" 未关联或未找到白名单规则 ({args.config})")
    print("=" * 62 + "\n")

    matched = []
    unmatched = []
    private_hosts = []

    for host, count in host_counts.most_common():
        if is_private_ip(host) or host == "localhost":
            private_hosts.append((host, count))
        elif matches_whitelist(host, whitelist):
            matched.append((host, count))
        else:
            base = get_base_domain(host)
            unmatched.append((host, count, base))

    # 输出未覆盖的域名
    if unmatched:
        print(f"【未覆盖的地址】(共 {len(unmatched)} 个，建议加入白名单):")
        print(f"  {'访问域名':<36} {'请求数':<8} {'建议后缀 (domain_suffix)'}")
        print(f"  {'-'*36} {'-'*8} {'-'*24}")
        suggested_suffixes = set()
        for host, count, base in unmatched:
            suggested_suffixes.add(base)
            print(f"  {host:<36} {count:<8} {base}")

        print("\n【建议直接复制到 config.json -> domain_suffix 的内容】:")
        print(json.dumps(sorted(list(suggested_suffixes)), indent=2, ensure_ascii=False))
    else:
        print("✔ 所有外网访问域名均已被当前白名单规则覆盖！")

    # 本地局域网地址
    if private_hosts:
        print(f"\n【本地 / 内网私有地址】(由 ip_is_private 规则直连):")
        for host, count in private_hosts:
            print(f"  {host:<36} ({count} 次请求)")

    # 如果指定了 --all 显示已覆盖的列表
    if args.all and matched:
        print(f"\n【已在白名单中的地址】(共 {len(matched)} 个):")
        for host, count in matched:
            print(f"  {host:<36} ({count} 次请求)")

    print()

if __name__ == "__main__":
    main()
