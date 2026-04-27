// ============ 配置区（只改这里）============
const PROXY = {
  name: "mitmproxy-relay",
  type: "http",
  server: "114.132.245.209",
  port: 8444,
  tls: true,
  "skip-cert-verify": true,
  sni: "hxe.7hu.cn",
};

// 需要捕获的域名规则，格式同 Clash rules（不带换行）
const RULES = [
  "DOMAIN,api.anthropic.com,mitmproxy-relay",
];

const VPS_IP = "114.132.245.209";

// 满足任一关键词的 proxy-group 都会注入此代理（大小写不敏感）
// 覆盖主流订阅的常见 group 名
const GROUP_KEYWORDS = ["节点选择", "proxy", "手动", "select", "global", "default"];
// ==========================================

function main(config) {
  injectProxy(config);
  injectToGroups(config);
  injectRules(config);
  injectTunExclude(config);
  return config;
}

function injectProxy(config) {
  if (!config.proxies) config.proxies = [];
  // 先删同名旧条目（兼容 server/port 更新的场景）
  config.proxies = config.proxies.filter(p => p.name !== PROXY.name);
  config.proxies.unshift(PROXY);
}

function injectToGroups(config) {
  if (!config["proxy-groups"]) return;
  for (const group of config["proxy-groups"]) {
    if (!matchesKeyword(group.name)) continue;
    if (!group.proxies) group.proxies = [];
    // 幂等：先删再插，确保始终在第一位
    group.proxies = group.proxies.filter(n => n !== PROXY.name);
    group.proxies.unshift(PROXY.name);
  }
}

function matchesKeyword(name) {
  if (!name) return false;
  const lower = name.toLowerCase();
  return GROUP_KEYWORDS.some(kw => lower.includes(kw.toLowerCase()));
}

function injectRules(config) {
  if (!config.rules) config.rules = [];
  // VPS IP 直连，防止流量回环
  const directRule = `IP-CIDR,${VPS_IP}/32,DIRECT,no-resolve`;
  config.rules = config.rules.filter(r => r !== directRule);

  // 捕获规则
  config.rules = config.rules.filter(r => !RULES.includes(r));

  // 顺序：VPS直连 → 捕获规则 → 原有规则
  config.rules.unshift(...RULES, directRule);
}

function injectTunExclude(config) {
  if (!config.tun) return;
  const key = "route-exclude-address";
  if (!config.tun[key]) config.tun[key] = [];
  const entry = `${VPS_IP}/32`;
  if (!config.tun[key].includes(entry)) {
    config.tun[key].push(entry);
  }
}
