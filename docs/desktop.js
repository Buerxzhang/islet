// 首页：宽屏时把整页变成一张仿 macOS 的桌面——菜单栏里有 islet 的灵动岛，点开是和软件一致的面板；
// 关于、功能、常见问题、设置都是桌面上的窗口。窄屏或没有脚本时，同一份内容按普通网页显示。所有数字都是示例数据。
(function () {
  const WIDE = 1000;
  if (window.innerWidth < WIDE) {
    // 窄屏保持普通网页；之后拉宽了就刷新成桌面
    window.addEventListener("resize", () => { if (window.innerWidth >= WIDE) location.reload(); });
    return;
  }
  document.documentElement.classList.add("desk");
  window.addEventListener("resize", () => { if (window.innerWidth < WIDE) location.reload(); });
  const root = document.body;

  // ---------- 小工具 ----------
  const $ = (sel, el = root) => el.querySelector(sel);
  const h = (html) => { const t = document.createElement("template"); t.innerHTML = html.trim(); return t.content.firstChild; };
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const walk = (v, step, lo, hi) => clamp(v + (Math.random() - 0.5) * step, lo, hi);
  const ICON = {
    gear: '<svg class="gear" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>',
    // 播放按钮的视图框裁到字形本身（软件也是先裁掉符号四周的留白，再按 10 点高显示），否则看起来会小一圈
    prev: '<svg class="ctl" viewBox="5 4 15 16"><path d="M5 4h3v16H5zM20 4v16L9 12z"/></svg>',
    next: '<svg class="ctl" viewBox="4 4 15 16"><path d="M16 4h3v16h-3zM4 4v16l11-8z"/></svg>',
    pause: '<svg class="ctl" viewBox="6 4 12 16"><path d="M6 4h4v16H6zM14 4h4v16h-4z"/></svg>',
    play: '<svg class="ctl" viewBox="6 4 14 16"><path d="M6 4l14 8-14 8z"/></svg>',
    keyboard: '<rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"/>',
    mouse: '<rect x="7" y="3" width="10" height="18" rx="5"/><path d="M12 7v4"/>',
    headphones: '<path d="M4.5 14v-2a7.5 7.5 0 0 1 15 0v2"/><rect x="3.5" y="13" width="4" height="6.5" rx="1.5"/><rect x="16.5" y="13" width="4" height="6.5" rx="1.5"/>',
    earbuds: '<path d="M7.5 4.5a3 3 0 0 1 3 3v11a1.5 1.5 0 0 1-3 0v-6a3 3 0 0 1 0-8zM16.5 4.5a3 3 0 0 0-3 3v11a1.5 1.5 0 0 0 3 0v-6a3 3 0 0 0 0-8z"/>',
    pad: '<path d="M7 8h10a4 4 0 0 1 3.9 4.9l-.8 3.6a2 2 0 0 1-3.5.8L15 15H9l-1.6 2.3a2 2 0 0 1-3.5-.8l-.8-3.6A4 4 0 0 1 7 8z"/><path d="M8 11v3M6.5 12.5h3"/>',
    speaker: '<rect x="3" y="7" width="18" height="10" rx="2"/><path d="M7 12h4"/>',
    monitor: '<rect x="3" y="4" width="18" height="12" rx="1.5"/><path d="M9 20h6M12 16v4"/>',
    usb: '<rect x="7" y="3" width="10" height="18" rx="2"/><circle cx="12" cy="14" r="3"/><path d="M12 7h.01"/>',
    radio: '<circle cx="12" cy="12" r="1.6" fill="#fff"/><path d="M8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M5.5 5.5a9.5 9.5 0 0 0 0 13M18.5 5.5a9.5 9.5 0 0 1 0 13"/>',
    trackpad: '<rect x="3" y="5" width="18" height="14" rx="2.5"/>',
    note: '<path d="M10 17.5V7l8-2v10.5"/><circle cx="8" cy="17.5" r="2" fill="#fff" stroke="none"/><circle cx="16" cy="15.5" r="2" fill="#fff" stroke="none"/>',
  };
  const svgIcon = (name, cls = "") => `<svg class="${cls}" viewBox="0 0 24 24">${ICON[name]}</svg>`;
  const K = "#1c1c1e";   // 实心图形里镂空部分的颜色（和岛的底色接近）
  const SOLID = {
    keyboard: `<rect x="1.5" y="6" width="21" height="12.5" rx="2.6" fill="#fff"/><path d="M5.5 10h1.2M9.3 10h1.2M13.1 10h1.2M16.9 10h1.2M7.5 14.4h9" stroke="${K}" stroke-width="1.7" stroke-linecap="round"/>`,
    mouse: `<rect x="6.2" y="2" width="11.6" height="20" rx="5.8" fill="#fff"/><path d="M12 5.6v4" stroke="${K}" stroke-width="1.8" stroke-linecap="round"/>`,
    headphones: `<path d="M4.4 15v-2.6a7.6 7.6 0 0 1 15.2 0V15" fill="none" stroke="#fff" stroke-width="2.6"/><rect x="2.6" y="13.2" width="5.4" height="8" rx="2.2" fill="#fff"/><rect x="16" y="13.2" width="5.4" height="8" rx="2.2" fill="#fff"/>`,
    earbuds: `<path d="M7.2 3.5a3.4 3.4 0 0 1 3.4 3.4v12.1a1.7 1.7 0 0 1-3.4 0v-6.1a3.4 3.4 0 0 1 0-9.4zM16.8 3.5a3.4 3.4 0 0 0-3.4 3.4v12.1a1.7 1.7 0 0 0 3.4 0v-6.1a3.4 3.4 0 0 0 0-9.4z" fill="#fff"/>`,
    pad: `<path d="M7 7h10a4.6 4.6 0 0 1 4.5 5.6l-.9 4.2a2.2 2.2 0 0 1-3.9.9L15.1 15.3H8.9l-1.6 2.4a2.2 2.2 0 0 1-3.9-.9l-.9-4.2A4.6 4.6 0 0 1 7 7z" fill="#fff"/><path d="M8 9.8v3.4M6.3 11.5h3.4" stroke="${K}" stroke-width="1.6" stroke-linecap="round"/><circle cx="15.8" cy="10.4" r="1.1" fill="${K}"/><circle cx="17.6" cy="12.6" r="1.1" fill="${K}"/>`,
    radio: `<circle cx="12" cy="12" r="2.4" fill="#fff"/><path d="M8.2 8.2a5.4 5.4 0 0 0 0 7.6M15.8 8.2a5.4 5.4 0 0 1 0 7.6M5 5a9.9 9.9 0 0 0 0 14M19 5a9.9 9.9 0 0 1 0 14" fill="none" stroke="#fff" stroke-width="2.3" stroke-linecap="round"/>`,
    trackpad: `<rect x="2.5" y="4.5" width="19" height="15" rx="2.6" fill="#fff"/>`,
  };
  const btLevel = (d) => (d.ears ? Math.min(...d.ears) : d.level);
  const batteryColor = (v) => (v <= 20 ? "#ff3b30" : v <= 40 ? "#ff9500" : "#34c759");
  const ringSVG = (pct, size, stroke, color, track = "rgba(255,255,255,0.18)") => {
    const r = (size - stroke) / 2, c = 2 * Math.PI * r;
    return `<svg class="r" viewBox="0 0 ${size} ${size}"><circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${track}" stroke-width="${stroke}"/>` +
      `<circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${color}" stroke-width="${stroke}" stroke-linecap="round" stroke-dasharray="${(c * pct) / 100} ${c}"/></svg>`;
  };
  // 网速单位：MB/s 或 Mb/s（岛上省掉 B / b，面板里写全）
  const bits = () => SET.netUnit === "Mb/s";
  const fmtRate = (kb) => { const v = bits() ? kb * 8 : kb; return v >= 1024 ? (v / 1024).toFixed(1) + "M" : Math.round(v) + "K"; };
  const fmtRateLong = (kb) => { const v = bits() ? kb * 8 : kb, u = bits() ? "b" : "B"; return v >= 1024 ? (v / 1024).toFixed(1) + ` M${u}/s` : v.toFixed(v < 10 ? 1 : 0) + ` K${u}/s`; };
  const fmtBytes = (kb) => (kb >= 1048576 ? (kb / 1048576).toFixed(2) + " GB" : kb >= 1024 ? (kb / 1024).toFixed(1) + " MB" : Math.round(kb) + " KB");
  // 温度单位
  const deg = (c) => (SET.tempUnit === "℉" ? Math.round(c * 9 / 5 + 32) : Math.round(c)) + "°";

  // ---------- 示例数据 ----------
  const apps = [
    { name: "浏览器", c: "#3b82f6", i: "浏" },
    { name: "音乐播放器", c: "#ef4467", i: "音" },
    { name: "聊天", c: "#22a35a", i: "聊" },
    { name: "代码编辑器", c: "#6366f1", i: "码" },
    { name: "文件管理", c: "#0ea5e9", i: "文" },
    { name: "邮件", c: "#0284c7", i: "邮" },
    { name: "照片", c: "#f59e0b", i: "照" },
    { name: "终端", c: "#52525b", i: "终" },
  ];
  const S = {
    cpu: 18, gpu: 32, mem: 10.2, pwr: 21, temp: 52, fan: 1000, down: 66, up: 4, fps: 118, diskRead: 2.4, diskWrite: 0.8, diskUsed: 51,
    today: 1.04 * 1048576, month: 28.78 * 1048576, volumes: [{ name: "备份盘", size: "1 TB · 已用 46%" }],
    hist: { cpu: [], gpu: [], mem: [], pwr: [], fan: [], down: [], up: [], disk: [], temp: [], fps: [] },
    playing: true, pausedAt: 0, track: 0, elapsed: 83, vol: 31, device: 0,
    bt: [
      { name: "Keys K2", icon: "keyboard", level: 82, on: true },
      { name: "Mouse M5", icon: "mouse", level: 15, on: true },
      { name: "AirPods Pro", icon: "earbuds", ears: [38, 45], box: 60, on: true },   // 左右耳、充电盒分开读；圆环取较低的一边
      { name: "Studio Headphones", icon: "headphones", level: 70, on: false },
      { name: "Game Pad", icon: "pad", level: 66, on: false },
      { name: "Pad Air", icon: "trackpad", level: 74, on: false },
    ],
    range: "5 分", killed: new Set(), strategy: "自动", preset: "均衡", awake: "关闭", awakeUntil: 0, awakeScreen: false, quit: false,
  };
  // 设置窗口里的选项（演示用），改了实时反映到灵动岛
  const SET = { page: "灵动岛", metsOpen: false, float: true, leftmost: true, bg: "渐变", other: true, collapse: "10 秒",
    shape: "竖条", color: "专辑色", spin: true, buttons: true, sens: "标准", smooth: false, dist: "中", soft: "中",
    hidpi: false, login: false, rate: "1 秒", autoUpdate: true,
    fanBasis: "平均温度", netMode: "自动", netUnit: "MB/s", btAlert: true, btLevel: "20%",
    fullFloat: false, freeDrag: false, reverse: false, rank: "8", tempUnit: "℃", monthStart: 1,
    // 提醒规则：和软件首次使用时一样，温度 ≥ 95° 持续 1 分钟（开）、CPU ≥ 90% 持续 3 分钟（关）
    rules: [{ kind: "温度", th: 95, min: 1, on: true }, { kind: "CPU", th: 90, min: 3, on: false }],
    split: true, metrics: true, btSound: true,   // 分体胶囊、“系统指标”模块整组开关、低电量提示音
    // 默认值和软件在刘海屏 MacBook 上新装时一致：悬浮、分体，只显示 CPU、内存、温度、网速；
    // 其余在“显示内容”里关着，可以打开开关，也可以右键「显示内容」勾选
    order: ["music", "cpu", "gpu", "fps", "mem", "disk", "pwr", "temp", "fan", "net", "bt"], hidden: new Set(["gpu", "fps", "disk", "pwr", "fan"]) };
  let settingsReady = false;
  const tracks = [
    { title: "Silver Coast", artist: "Lumen Drift", len: 240, from: "#ff7a45", via: "#c23a6b", to: "#7a2a8c", bar: "#e5577a", bg: "#fbd9e1" },
    { title: "Night Transit", artist: "Northbound", len: 243, from: "#3a7bd5", via: "#4a4ab8", to: "#1d1f5e", bar: "#4f7ce0", bg: "#dbe4fb" },
    { title: "Paper Sun", artist: "Mira Vale", len: 158, from: "#ffd166", via: "#f4a259", to: "#e76f51", bar: "#e8913c", bg: "#fde9cf" },
  ];
  for (let i = 0; i < 60; i++) {
    S.hist.cpu.push(14 + Math.sin(i / 6) * 6 + Math.random() * 6);
    S.hist.gpu.push(26 + Math.sin(i / 8) * 8 + Math.random() * 6);
    S.hist.mem.push(62 + Math.random() * 3);
    S.hist.pwr.push(16 + Math.sin(i / 5) * 5 + Math.random() * 4);
    S.hist.fan.push(1000 + Math.max(0, Math.sin(i / 9)) * 180 + Math.random() * 30);
    S.hist.down.push(40 + Math.sin(i / 5) * 30 + Math.random() * 25);
    S.hist.up.push(3 + Math.random() * 4);
    S.hist.disk.push(1 + Math.max(0, Math.sin(i / 4)) * 4 + Math.random());
    S.hist.temp.push(50 + Math.sin(i / 10) * 3 + Math.random());
    S.hist.fps.push(110 + Math.random() * 10);
  }

  // ---------- 骨架 ----------
  const mount = $(".island-mount");
  mount.innerHTML = `
<div class="island">
  <div class="seg music" data-p="music"><span class="cover"></span><span class="ctls"><i data-ctl="prev">${ICON.prev}</i><i class="pp" data-ctl="toggle"></i><i data-ctl="next">${ICON.next}</i></span><span class="bars"></span><span class="app-ic"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round">${ICON.note}</svg></span></div>
  <span class="divider"></span>
  <div class="seg metric" data-p="cpu"><b>CPU</b><span id="v-cpu"></span></div>
  <div class="seg metric" data-p="gpu"><b>GPU</b><span id="v-gpu"></span></div>
  <div class="seg metric" data-p="fps"><b>FPS</b><span id="v-fps"></span></div>
  <div class="seg metric" data-p="mem"><b>MEM</b><span id="v-mem"></span></div>
  <div class="seg metric" data-p="disk"><b>DISK</b><span id="v-disk"></span></div>
  <div class="seg metric" data-p="pwr"><b id="l-pwr">PWR</b><span id="v-pwr"></span></div>
  <div class="seg metric" data-p="temp"><b>TEMP</b><span id="v-temp"></span></div>
  <div class="seg metric" data-p="fan"><b>FAN</b><span id="v-fan"></span></div>
  <div class="seg net" data-p="net"></div>
  <div class="seg bt" data-p="bt"></div>
</div>`;
  root.appendChild(h('<div class="panel"></div>'));

  const island = $(".island"), panel = $(".panel");
  const barsEl = $(".island .bars");
  for (let i = 0; i < 24; i++) barsEl.appendChild(document.createElement("i"));   // 和软件一样 24 根

  // ---------- 灵动岛 ----------
  function renderIsland() {
    $("#v-cpu").textContent = Math.round(S.cpu) + "%";
    $("#v-gpu").textContent = Math.round(S.gpu) + "%";
    $("#v-mem").textContent = S.mem.toFixed(1) + "G";
    $("#v-pwr").textContent = Math.round(S.pwr) + "W";
    if (S.awake !== "关闭" && S.awakeUntil && Date.now() > S.awakeUntil) S.awake = "关闭";
    $("#l-pwr").textContent = S.awake === "关闭" ? "PWR" : "AWAKE";
    $("#v-fan").textContent = Math.round(S.fan);
    $("#v-fps").textContent = Math.round(S.fps);
    $("#v-disk").textContent = S.diskUsed + "%";
    $("#v-temp").textContent = deg(S.temp);
    // 网速：自动时只显示较快的一方（NET + 箭头）；“上传和下载”时两列 UP / DOWN；有流量时箭头亮起（下载蓝、上传绿）
    const arrow = (dir, kb) => `<em class="${kb > 1 ? (dir === "↓" ? "dn" : "upc") : "idle"}">${dir}</em>${fmtRate(kb)}`;
    $(".island .net").innerHTML = SET.netMode === "上传和下载"
      ? `<span class="metric"><b>UP</b><span>${arrow("↑", S.up)}</span></span><span class="metric"><b>DOWN</b><span>${arrow("↓", S.down)}</span></span>`
      : `<span class="metric"><b>NET</b><span>${S.up > S.down ? arrow("↑", S.up) : arrow("↓", S.down)}</span></span>`;
    const t = tracks[S.track];
    $(".island .cover").style.background = `linear-gradient(135deg, ${t.from}, ${t.via} 55%, ${t.to})`;
    $(".island .pp").innerHTML = S.playing ? ICON.pause : ICON.play;
    // 底色（和软件一致）：渐变——从左往右过渡到黑，起点播放时是专辑色、没播放时是主题蓝 #0096d6 的深色版；黑色；玻璃只在悬浮时（菜单栏里按黑色）
    const glass = SET.bg === "玻璃" && SET.float;
    const bg = glass ? "rgba(0,0,0,0.42)" : SET.bg !== "黑色"   // 不悬浮时的玻璃按渐变画
      ? `linear-gradient(90deg, ${S.playing ? `color-mix(in srgb, ${t.via} 70%, #000)` : "#004b6b"} 0%, #0f0f10 100%)` : "#000";
    island.classList.toggle("glass", glass);
    island.style.setProperty("--ibg", bg);   // 分体时每个小胶囊用同一个底色（按整条胶囊铺开，见 alignBackdrop）
    island.style.background = SET.split ? "transparent" : bg;
    island.classList.toggle("float", SET.float);
    island.classList.toggle("split", SET.split);
    if (!SET.float || !SET.freeDrag) Object.assign(island.style, { left: "", top: "", transform: "" });
    $(".island .cover").classList.toggle("spin", SET.spin && S.playing);
    $(".island .ctls").style.display = SET.buttons ? "" : "none";
    barsEl.classList.toggle("dots", SET.shape === "点阵");
    const barColor = SET.color === "白色" ? "#f2f2f2" : SET.color === "图标色" ? "#ff5a5a" : t.bar;
    island.style.setProperty("--bar", `color-mix(in srgb, ${barColor} 80%, #fff)`);   // 深色底上调浅一些，按钮同色
    // 演示里放的都是音乐软件：暂停时一直显示（和软件一致，退出音乐软件才收起）
    const hidden = false;
    arrangeIsland(hidden);
    alignBackdrop();
    // 蓝牙：每台设备一个圆环，环是电量；读不到电量的只画灰色底环
    $(".island .bt").innerHTML = S.bt.filter((d) => d.on).map((d) =>
      `<span class="ring">${ringSVG(btLevel(d) ?? 0, 16, 2, btLevel(d) == null ? "transparent" : batteryColor(btLevel(d)))}<svg class="g" viewBox="0 0 24 24">${SOLID[d.icon]}</svg></span>`).join("");
  }
  // 按设置里的顺序排列各项，“未显示”的不出现；分隔线跟在音乐旁边（音乐在最右时放在它左边）
  // 三个模块：音乐、系统指标（各项指标）、蓝牙电量。分体时相邻的同一模块合成一个小胶囊（.grp），合体时 .grp 不占位
  const isModule = (id) => id === "music" || id === "metrics" || id === "bt";
  const kindOf = (id) => (id === "music" ? 0 : id === "bt" ? 2 : 1);
  const onIsland = (id) => !SET.hidden.has(id) && (isModule(id) || SET.metrics);
  // 分体时三个小胶囊共用一条渐变（和软件一致）：渐变按整条胶囊的宽度铺开，每段只露出自己那一截，
  // 而不是每段各画一遍完整渐变。胶囊宽度变化（音乐展开 / 收起）时重新对齐
  function alignBackdrop() {
    const width = island.scrollWidth;
    island.querySelectorAll(".grp").forEach((g) => {
      g.style.backgroundSize = SET.split ? `${width}px 100%` : "";
      g.style.backgroundPosition = SET.split ? `${-g.offsetLeft}px 0` : "";
    });
  }
  new ResizeObserver(alignBackdrop).observe(island);
  let lastArrange = "";
  function arrangeIsland(musicCollapsed) {
    const ids = (SET.split ? grouped(SET.order) : SET.order).filter((id) => onIsland(id) && !(id === "music" && musicCollapsed));
    const key = ids.join(",") + (SET.split ? "|split" : "");
    if (key === lastArrange) return;
    lastArrange = key;
    const divider = island.querySelector(".divider");
    island.querySelectorAll(".seg").forEach((el) => { el.style.display = ids.includes(el.dataset.p) ? "" : "none"; island.appendChild(el); });
    island.appendChild(divider);
    island.querySelectorAll(".grp").forEach((g) => g.remove());
    let grp = null, kind = -1;
    ids.forEach((id) => {
      if (kindOf(id) !== kind) { kind = kindOf(id); grp = document.createElement("div"); grp.className = "grp"; island.appendChild(grp); }
      grp.appendChild(island.querySelector(`.seg[data-p="${id}"]`));
    });
    const m = ids.indexOf("music");
    divider.style.display = m >= 0 && ids.length > 1 && !SET.split ? "" : "none";
    if (m >= 0 && ids.length > 1) {
      const music = island.querySelector('.seg[data-p="music"]');
      if (m < ids.length - 1) music.after(divider); else music.before(divider);
    }
    island.style.display = ids.length ? "" : "none";
    if (open && !ids.includes(open)) toggle(open, island.querySelector(`[data-p="${open}"]`));
  }

  // 菜单栏右侧的日期和时间
  const clock = () => {
    const d = new Date(), p = (n) => String(n).padStart(2, "0");
    $(".mdate").textContent = `${d.getMonth() + 1}月${d.getDate()}日 周${"日一二三四五六"[d.getDay()]}`;
    $(".mtime").textContent = `${p(d.getHours())}:${p(d.getMinutes())}`;
  };
  clock();
  setInterval(clock, 1000);

  // 频谱：模拟真实音频——每 ~140 毫秒换一组目标值（低频高、高频低，偶尔有重拍），上升快、回落慢
  const levels = new Array(26).fill(0), targets = new Array(26).fill(0);
  let beat = 0;
  setInterval(() => {
    const gain = { 低: 0.7, 标准: 1, 高: 1.25 }[SET.sens];
    beat = Math.random() < 0.28 ? 1 : beat * 0.55;
    for (let i = 0; i < targets.length; i++) {
      const shape = Math.exp(-Math.pow((i - 6) / 7.5, 2)) * 0.8 + 0.12;
      const v = shape * (0.55 + 0.35 * Math.random() + 0.25 * beat * (i < 9 ? 1 : 0.4));
      targets[i] = S.playing ? clamp(gain * v, 0.05, 1) : 0;
    }
  }, 140);
  function animate() {
    for (let i = 0; i < levels.length; i++) {
      const k = targets[i] > levels[i] ? 0.28 : 0.09;
      levels[i] += (targets[i] - levels[i]) * k;
    }
    barsEl.querySelectorAll("i").forEach((b, i) => { b.style.height = (S.playing ? Math.max(2, levels[i] * 16) : 2) + "px"; });
    if (viz) drawVisualizer();
    const mb = panel.querySelector(".mbars");
    if (mb) mb.querySelectorAll("i").forEach((b, i) => { b.style.height = Math.max(10, levels[i] * 100) + "%"; });
    requestAnimationFrame(animate);
  }

  // ---------- 全屏频谱：照软件的 Visualizer——封面模糊做背景，歌名居中大字，72 根频谱铺满下半屏并带倒影 ----------
  let viz = null, vizTimer = 0;
  const VIZ_BARS = 72;
  function openVisualizer() {
    const t = tracks[S.track];
    viz = h(`<div class="viz" role="dialog" aria-label="全屏频谱">
      <div class="viz-bg"><div class="viz-art" style="background:linear-gradient(135deg, ${t.from}, ${t.via} 55%, ${t.to})"></div></div>
      <div class="viz-title"><b></b><span></span><em><i></i>音乐播放器</em></div>
      <canvas class="viz-spec"></canvas>
      <div class="viz-ctl"><button data-v="prev">${ICON.prev}</button><button data-v="toggle"></button><button data-v="next">${ICON.next}</button><span class="viz-time"></span><span class="viz-prog"><em></em></span></div>
      <div class="viz-top"><span class="viz-note">示例数据</span><button class="viz-close" aria-label="退出全屏"><svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg></button></div>
      <div class="viz-edge"><em></em></div></div>`);
    root.appendChild(viz);
    syncVisualizer();
    showVizControls();
    requestAnimationFrame(() => viz && viz.classList.add("show"));
    viz.addEventListener("mousemove", showVizControls);
    viz.querySelector(".viz-close").addEventListener("click", closeVisualizer);
    viz.querySelector(".viz-ctl").addEventListener("click", (e) => {
      const v = e.target.closest("[data-v]")?.dataset.v;
      if (v === "toggle") { S.playing = !S.playing; S.pausedAt = Date.now(); }
      if (v === "next" || v === "prev") { S.track = (S.track + (v === "next" ? 1 : tracks.length - 1)) % tracks.length; S.elapsed = 0; S.playing = true; }
      if (v) { renderIsland(); syncVisualizer(); }
    });
  }
  // 鼠标一动显示控件和关闭按钮，静止 2.5 秒后隐藏
  function showVizControls() {
    if (!viz) return;
    viz.classList.add("controls");
    clearTimeout(vizTimer);
    vizTimer = setTimeout(() => viz && viz.classList.remove("controls"), 2500);
  }
  function syncVisualizer() {
    if (!viz) return;
    const t = tracks[S.track], fmt = (x) => Math.floor(x / 60) + ":" + String(Math.floor(x % 60)).padStart(2, "0");
    viz.querySelector(".viz-art").style.background = `linear-gradient(135deg, ${t.from}, ${t.via} 55%, ${t.to})`;
    viz.querySelector(".viz-title b").textContent = t.title;
    viz.querySelector(".viz-title span").textContent = t.artist;
    viz.querySelector(".viz-title").classList.toggle("paused", !S.playing);
    viz.querySelector(".viz-title i").style.background = S.playing ? "#30d158" : "#8e8e93";
    viz.querySelector('[data-v="toggle"]').innerHTML = S.playing ? ICON.pause : ICON.play;
    viz.querySelector(".viz-time").textContent = `${fmt(S.elapsed)} / ${fmt(t.len)}`;
    viz.querySelector(".viz-prog em").style.width = viz.querySelector(".viz-edge em").style.width = (S.elapsed / t.len) * 100 + "%";
  }
  function drawVisualizer() {
    const c = viz.querySelector(".viz-spec"), dpr = window.devicePixelRatio || 1;
    const W = c.clientWidth, H = c.clientHeight;
    if (c.width !== Math.round(W * dpr)) { c.width = Math.round(W * dpr); c.height = Math.round(H * dpr); }
    const g = c.getContext("2d");
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, W, H);
    const tint = tracks[S.track].bar;
    const gap = Math.max(W / VIZ_BARS * 0.32, 2), w = (W - gap * (VIZ_BARS - 1)) / VIZ_BARS, mid = H * 0.78;
    const grad = g.createLinearGradient(0, mid, 0, 0);
    grad.addColorStop(0, tint); grad.addColorStop(0.5, tint); grad.addColorStop(1, "#fff");
    const refl = g.createLinearGradient(0, mid, 0, mid + H * 0.22);
    refl.addColorStop(0, tint + "59"); refl.addColorStop(1, tint + "00");
    for (let i = 0; i < VIZ_BARS; i++) {
      // 横轴按频率的对数刻度排：低频占的宽度少，整排起伏更均匀（和软件全屏时的样子接近）
      const x0 = Math.pow(i / (VIZ_BARS - 1), 1.8) * (levels.length - 1), lo = Math.floor(x0), f = x0 - lo;
      const level = levels[lo] * (1 - f) + levels[Math.min(lo + 1, levels.length - 1)] * f;
      const hgt = Math.max(w, mid * Math.pow(Math.min(level * 1.05, 1), 2.2) * 0.96), x = i * (w + gap);
      g.fillStyle = grad; g.beginPath(); g.roundRect(x, mid - hgt, w, hgt, w / 2); g.fill();
      g.fillStyle = refl; g.beginPath(); g.roundRect(x, mid + 4, w, hgt * 0.35, w / 2); g.fill();
    }
  }
  function closeVisualizer() {
    if (!viz) return;
    const v = viz; viz = null;
    clearTimeout(vizTimer);
    v.classList.remove("show");
    setTimeout(() => v.remove(), 300);
  }
  window.addEventListener("keydown", (e) => { if (e.key === "Escape") closeVisualizer(); });

  // ---------- 面板 ----------
  let open = null;
  const chartPath = (arr, max, w, hgt) => {
    const step = w / (arr.length - 1);
    const pts = arr.map((v, i) => [i * step, hgt - (v / max) * (hgt - 4)]);
    return pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ");
  };
  function chart(series, colors, fills) {
    const w = 276, hgt = 56, max = Math.max(...series.flat(), 1) * 1.15;
    let out = `<svg class="chart" viewBox="0 0 ${w} ${hgt}" preserveAspectRatio="none">`;
    // 颜色可以是 CSS 变量（压力色随深浅色变），所以用 style 而不是属性；fills[k] 为真时画同色浅底
    series.forEach((arr, k) => {
      const d = chartPath(arr, max, w, hgt);
      if (fills[k]) out += `<path d="${d} L${w} ${hgt} L0 ${hgt} Z" style="fill:${colors[k]};fill-opacity:.16"/>`;
      out += `<path d="${d}" fill="none" style="stroke:${colors[k]}" stroke-width="1.4" stroke-linejoin="round"/>`;
    });
    return out + `<line x1="0" y1="${hgt - 0.5}" x2="${w}" y2="${hgt - 0.5}" stroke="rgba(0,0,0,0.12)"/></svg>`;
  }
  // 圆环（和软件的 Ring 一致）：small 写成“单位 说明”时，单位跟在数字后面（小一号），下面只写说明，如 18% / 占用
  const gauge = (pct, big, small, dot, color = "var(--pn-accent)") => {
    const r = 42, c = 2 * Math.PI * r;
    const len = dot ? 0.1 : Math.max((c * pct) / 100, c * 0.015);   // 0 时也留一点
    const arc = `<circle cx="48" cy="48" r="${r}" fill="none" style="stroke:${color}" stroke-width="9" stroke-linecap="round" stroke-dasharray="${len} ${c}"/>`;
    const parts = small.split(" "), unit = parts.length === 2 ? parts[0] : "", label = parts.length === 2 ? parts[1] : small;
    const tight = unit === "%" || unit.startsWith("°");
    return `<div class="gauge"><svg viewBox="0 0 96 96"><circle cx="48" cy="48" r="${r}" fill="none" style="stroke:var(--pn-inset)" stroke-width="9"/>${arc}</svg>` +
      `<div class="v"><b>${big}${unit ? `<i>${tight ? "" : " "}${unit}</i>` : ""}</b><small>${label}</small></div></div>`;
  };
  // 压力色（和软件的 Metric.level 同一套阈值）：CPU / GPU 70 / 90%，温度 80 / 95°，磁盘 85 / 95%；正常绿、偏高橙、很高红
  const levelColor = (v, warn, alarm) => (v >= alarm ? "var(--pn-hot)" : v >= warn ? "var(--pn-warm)" : "var(--pn-cool)");
  const segctl = () => `<div class="segctl">${["5 分", "1 时", "24 时"].map((r) => `<button class="${r === S.range ? "sel" : ""}" data-range="${r}">${r}</button>`).join("")}</div>`;
  // 面板标题栏：右上角是设置（齿轮），和软件一致
  const header = (icon, title, extra = "") => `<div class="ph">${icon}<span class="t">${title}</span>${extra}<span class="gearbtn" data-act="settings" title="设置">${ICON.gear}</span></div>`;
  const footer = (left) => `<div class="pf"><span>${left}</span><span><b data-act="diag">诊断</b><b data-act="quit">退出</b></span></div>`;
  const rankRow = (a, share, nums) => `<div class="rank-r${nums.length > 1 ? " two" : ""}"><span class="ic" style="background:${a.c}">${a.i}</span><span class="nm"><div>${a.name}</div><em style="width:${share}%"></em></span>${nums.map((n) => `<span class="num">${n}</span>`).join("")}<button class="kill" data-kill="${a.name}" title="结束">结束</button></div>`;
  const liveApps = () => apps.filter((a) => !S.killed.has(a.name));
  // 切换走势范围时，用不同的平滑程度模拟更长的时间段
  const ranged = (arr) => {
    if (S.range === "5 分") return arr;
    const k = S.range === "1 时" ? 4 : 10;
    return arr.map((_, i) => { const s = arr.slice(Math.max(0, i - k), i + 1); return s.reduce((a, b) => a + b, 0) / s.length; });
  };

  const metricConf = {
    cpu: { title: "CPU", tint: "#0a84ff", level: () => levelColor(S.cpu, 70, 90), icon: '<svg viewBox="0 0 24 24" fill="none" stroke="#0096d6" stroke-width="1.8"><rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/></svg>',
      gauge: () => [S.cpu, Math.round(S.cpu), "% 占用"], kv: () => [["核心", "4 性能 + 6 能效"], ["温度", deg(S.temp + 4)], ["功耗", S.pwr.toFixed(1) + " W"]],
      hist: "cpu", peak: (m) => "峰值 " + Math.round(m) + "%", rank: "CPU 占用", share: [38, 12, 6.4, 4.1, 1.2, 0.8, 0.5, 0.3], fmt: (v) => v + "%" },
    gpu: { title: "GPU", tint: "#5e5ce6", level: () => levelColor(S.gpu, 70, 90), icon: '<svg viewBox="0 0 24 24" fill="none" stroke="#0096d6" stroke-width="1.8"><rect x="2" y="6" width="20" height="12" rx="2"/><circle cx="9" cy="12" r="3"/><path d="M15 10h4M15 14h4"/></svg>',
      gauge: () => [S.gpu, Math.round(S.gpu), "% 占用"], kv: () => [["核心", "16 核"], ["温度", deg(S.temp - 3)], ["功耗", (S.pwr * 0.3).toFixed(1) + " W"]],
      hist: "gpu", peak: (m) => "峰值 " + Math.round(m) + "%", rank: "GPU 占用", share: [21, 6.2, 2.4, 1.1, 0.3, 0.2, 0.1, 0.1], fmt: (v) => v + "%" },
    mem: { title: "内存", tint: "#30d158", level: () => "var(--pn-cool)", icon: '<svg viewBox="0 0 24 24" fill="none" stroke="#0096d6" stroke-width="1.8"><rect x="3" y="7" width="18" height="10" rx="1.5"/><path d="M7 7v10M11 7v10M15 7v10M7 20v-3M17 20v-3"/></svg>',
      gauge: () => [S.mem / 16 * 100, S.mem.toFixed(1), "GB 已用"], kv: () => [["总量", "16 GB"], ["压力", "正常"], ["交换", "0.8 GB"]],
      hist: "mem", peak: (m) => "峰值 " + (m * 0.16).toFixed(1) + " GB", rank: "内存占用", share: [2.8, 0.9, 0.7, 0.6, 0.2, 0.18, 0.12, 0.05], fmt: (v) => v + " GB" },
    pwr: { title: "功耗", tint: "#ffb800", icon: '<svg viewBox="0 0 24 24" fill="none" stroke="#0096d6" stroke-width="1.8"><path d="M13 2L4 14h7l-1 8 9-12h-7z"/></svg>',
      gauge: () => [S.pwr / 60 * 100, Math.round(S.pwr), "W 功耗"], kv: () => [["峰值", "38 W"], ["温度", deg(S.temp)], ["风扇", Math.round(S.fan) + " 转"]],
      hist: "pwr", peak: (m) => "峰值 " + Math.round(m) + " W", rank: "应用功耗", share: [6.1, 2.2, 1.4, 0.9, 0.2, 0.15, 0.1, 0.05], fmt: (v) => v + " W" },
    disk: { title: "磁盘", tint: "#8e8e93", level: () => levelColor(S.diskUsed, 85, 95), icon: '<svg viewBox="0 0 24 24" fill="none" stroke="#0096d6" stroke-width="1.8"><rect x="3" y="6" width="18" height="12" rx="2"/><path d="M7 14h.01M11 14h6"/></svg>',
      gauge: () => [S.diskUsed, S.diskUsed, "% 已用"], kv: () => [["可用", "245 GB"], ["读取", S.diskRead.toFixed(1) + " MB/s"], ["写入", S.diskWrite.toFixed(1) + " MB/s"]],
      hist: "disk", peak: (m) => "峰值 " + m.toFixed(1) + " MB/s", rank: "磁盘读写", two: ["读取", "写入"], share: [[42, 8], [12, 2], [6, 3], [3, 1], [2, 0.5], [1, 0.2], [0.5, 0.1], [0.2, 0]], fmt: (v) => v + " MB" },
    temp: { title: "温度", tint: "#ff9f0a", level: () => levelColor(S.temp, 80, 95), icon: '<svg viewBox="0 0 24 24" fill="none" stroke="#0096d6" stroke-width="1.8"><path d="M14 14.8V4a2 2 0 0 0-4 0v10.8a4 4 0 1 0 4 0z"/></svg>',
      gauge: () => [S.temp / 110 * 100, deg(S.temp).replace("°", ""), "° 平均"], kv: () => [["最热", deg(S.temp + 7) + " CPU 性能核"], ["CPU", deg(S.temp + 4)], ["GPU", deg(S.temp - 3)]],
      hist: "temp", peak: (m) => "最高 " + deg(m) },
    fps: { title: "帧率", tint: "#ff375f", icon: '<svg viewBox="0 0 24 24" fill="none" stroke="#0096d6" stroke-width="1.8"><path d="M4 16a8 8 0 1 1 16 0"/><path d="M12 16l4-5"/></svg>',
      gauge: () => [S.fps / 120 * 100, Math.round(S.fps), "fps 帧率"], kv: () => [["屏幕", "内建显示器"], ["刷新率", "120 Hz"], ["状态", "测量中"]],
      hist: "fps", peak: (m) => "峰值 " + Math.round(m) + " 帧" },
    fan: { title: "风扇", tint: "#30b0c7", icon: '<svg viewBox="0 0 24 24" fill="none" stroke="#0096d6" stroke-width="1.8"><circle cx="12" cy="12" r="1.5"/><path d="M12 10.5C11 6 12 3 15 3s3 4-3 7.5zM13.5 12c4.5-1 7.5 0 7.5 3s-4 3-7.5-3zM12 13.5c1 4.5 0 7.5-3 7.5s-3-4 3-7.5zM10.5 12C6 13 3 12 3 9s4-3 7.5 3z"/></svg>',
      gauge: () => [(S.fan - 1000) / 40 + 10, Math.round(S.fan), "转 当前转速"], kv: () => [["目标", String(Math.round(S.fan / 10) * 10)], ["区间", "1000–4900"], ["模式", S.strategy]],
      hist: "fan", peak: (m) => "峰值 " + Math.round(m) + " 转", rank: "发热来源", rankTrailing: "按功耗", limit: 3, share: [6.1, 2.2, 1.4, 0.9, 0.2, 0.15, 0.1, 0.05], fmt: (v) => v + " W" },
  };

  function metricPanel(key) {
    const m = metricConf[key], [pct, big, small] = m.gauge();
    const data = ranged(S.hist[m.hist]);
    // 有压力的项（CPU、GPU、内存、磁盘、温度）圆环和走势线按压力变色，其他用这一项的固定颜色；标题图标用固定颜色
    const color = m.level ? m.level() : m.tint;
    let html = header(m.icon.replaceAll("#0096d6", m.tint), m.title) + `<div class="pc"><div class="hero-row">${gauge(pct, big, small, false, color)}<dl class="kv">${m.kv().map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join("")}</dl></div>${segctl()}${chart([data], [color], [true])}<div class="chart-foot"><span></span><span>${m.peak(Math.max(...data))}</span></div></div>`;
    if (key === "fan") {
      html += `<div class="sec">硬件温度<small>调速依据：${SET.fanBasis} ${deg(SET.fanBasis === "最高温度" ? S.temp + 7 : S.temp)}</small></div><div class="pc rows">${[["CPU 性能核", S.temp + 6], ["CPU 能效核", S.temp - 2], ["GPU", S.temp - 3], ["内存", 41], ["硬盘", 38]].map(([n, v]) => `<div class="r"><span>${n}</span><span>${deg(v)}</span></div>`).join("")}</div>`;
      const PRESETS = { 静音: "75℃ 以下几乎不介入，温度换噪音", 均衡: "60℃ 起提速，90℃ 全速", 性能: "35℃ 起就给基础转速，优先压温" };
      const two = (a, b, right = "") => `<div class="sw"><div><div>${a}</div><small class="muted">${b}</small></div>${right}</div>`;
      const body = {
        自动: '<p class="tip">风扇由 macOS 控制。选择其他策略时，会安装一个以管理员权限运行的小组件来调速。</p>',
        固定: `<div class="r"><span>固定转速</span><span>2400 转</span></div><p class="tip">温度超过 85℃ 时会按安全下限自动提速</p>`,
        温度曲线: two("曲线预设", PRESETS[S.preset], `<select class="sel" data-preset="1">${Object.keys(PRESETS).map((k) => `<option${k === S.preset ? " selected" : ""}>${k}</option>`).join("")}</select>`),
        规则: two("2 条规则 · 启用 2 条", "都未触发时由系统控制；规则在设置里编辑"),
      }[S.strategy];
      const status = { 自动: "系统控制中", 固定: "接管中 · 目标 2400 转", 温度曲线: `接管中 · 目标 ${Math.round(S.fan / 10) * 10} 转`, 规则: "规则未触发 · 系统控制" }[S.strategy];
      html += `<div class="sec">调速策略<small>${status}</small></div><div class="segctl full">${["自动", "固定", "温度曲线", "规则"].map((o) => `<button class="${o === S.strategy ? "sel" : ""}" data-strategy="${o}">${o}</button>`).join("")}</div><div class="pc">${body}</div>`;
    }
    if (key === "temp") {   // 按部件分组的传感器读数
      const groups = [["CPU", [["性能核 1", S.temp + 7], ["性能核 2", S.temp + 5], ["能效核", S.temp - 2]]], ["GPU", [["GPU 1", S.temp - 2], ["GPU 2", S.temp - 4]]], ["其他", [["内存", 41], ["硬盘", 38], ["电源", 36]]]];
      html += `<div class="sec">硬件温度<small>8 个传感器</small></div>` + groups.map(([g, list]) => `<div class="pc rows grp"><div class="r"><span><b>${g}</b></span><span>${deg(list.reduce((a, b) => a + b[1], 0) / list.length)}</span></div>${list.map(([n, v]) => `<div class="r"><span>${n}</span><span>${deg(v)}</span></div>`).join("")}</div>`).join("");
    }
    if (key === "fps") {
      html += `<div class="sec">说明</div><div class="pc"><p class="tip">统计前台窗口所在屏幕每秒画面变化的次数（islet 自己不算）。画面静止时数字会变低，最高不超过屏幕刷新率；游戏自身的渲染帧率以游戏内计数器为准。</p></div>`;
    }
    if (key === "disk") {
      html += `<div class="sec">硬盘健康<small>SMART 自检</small></div><div class="pc rows"><div class="r"><span>内置固态硬盘</span><span class="ok">正常 · 寿命剩余 98%</span></div><div class="r"><span>已写入</span><span>18.6 TB</span></div></div>`;
      html += `<div class="sec">外接磁盘<small>${S.volumes.length ? S.volumes.length + " 个" : ""}</small></div><div class="pc">${S.volumes.length ? S.volumes.map((v, i) => `<div class="vol-row"><span><b>${v.name}</b><small>${v.size}</small></span><button data-eject="${i}">推出</button></div>`).join("") : '<p class="tip">没有外接磁盘</p>'}</div>`;
    }
    if (key === "pwr") {
      const remain = S.awakeUntil ? Math.max(0, Math.round((S.awakeUntil - Date.now()) / 1000)) : 0;
      const trailing = S.awake === "关闭" ? "" : S.awake === "一直" ? "直到手动关闭" : `剩余 ${Math.floor(remain / 3600)}:${String(Math.floor(remain / 60) % 60).padStart(2, "0")}:${String(remain % 60).padStart(2, "0")}`;
      html += `<div class="sec">保持唤醒<small>${trailing}</small></div><div class="pc"><div class="segctl full" style="margin:0 0 8px">${["关闭", "30 分钟", "2 小时", "一直"].map((o) => `<button class="${o === S.awake ? "sel" : ""}" data-awake="${o}">${o}</button>`).join("")}</div>` +
        `<p class="tip">${S.awake === "一直" ? "电脑不自动睡眠，重启 islet 后也保持" : "电脑不自动睡眠，适合下载、渲染"}</p><div class="sw"><div>屏幕常亮</div><span class="tg${S.awakeScreen ? " on" : ""}" data-awscreen="1"></span></div></div>`;
    }
    if (m.rank && m.two) {
      const list = liveApps().slice(0, +SET.rank), max = Math.max(...list.map((a) => m.share[apps.indexOf(a)][0]), 0.1);
      html += `<div class="sec">${m.rank}</div><div class="pc"><div class="rank-h two"><span>应用</span><span class="num">${m.two[0]}</span><span class="num">${m.two[1]}</span></div>${list.map((a) => { const v = m.share[apps.indexOf(a)]; return rankRow(a, (v[0] / max) * 100, [m.fmt(v[0]), m.fmt(v[1])]); }).join("")}</div>`;
    } else if (m.rank) {
      const list = liveApps().slice(0, Math.min(m.limit || 99, +SET.rank)), max = Math.max(...list.map((a) => m.share[apps.indexOf(a)]), 0.1);
      html += `<div class="sec">${m.rank}${m.rankTrailing ? `<small>${m.rankTrailing}</small>` : ""}</div><div class="pc"><div class="rank-h"><span>应用</span><span class="num">${key === "fan" || key === "pwr" ? "功耗" : m.title}</span></div>${list.map((a) => rankRow(a, (m.share[apps.indexOf(a)] / max) * 100, [m.fmt(m.share[apps.indexOf(a)])])).join("") || '<div class="tip">当前没有明显的占用</div>'}</div>`;
    }
    return html + footer("采样 " + (30 + Math.round(Math.random() * 20)) + " ms");
  }

  function netPanel() {
    const down = ranged(S.hist.down), up = ranged(S.hist.up);
    const flows = [[1.8 * 1024, 96], [420, 12], [86, 40], [12, 3], [2, 0], [1, 0.5], [0.6, 0.2], [0.2, 0.1]];
    const max = flows[0][0];
    const kb = (v) => fmtBytes(v).replace(" ", "");
    const big = fmtRateLong(S.down).split(" ");
    return header('<svg viewBox="0 0 24 24" fill="none" stroke="#0a84ff" stroke-width="2"><path d="M7 20V4M3 8l4-4 4 4M17 4v16M13 16l4 4 4-4"/></svg>', "网速") +
      `<div class="pc"><div class="hero-row">${gauge(0, big[0], big[1] + " 下载", true, "#0a84ff")}<dl class="kv"><dt>上传</dt><dd>${fmtRateLong(S.up)}</dd><dt>今日</dt><dd>${fmtBytes(S.today)}</dd><dt>本月</dt><dd>${fmtBytes(S.month)}</dd></dl></div>${segctl()}` +
      `${chart([down, up], ["#0a84ff", "var(--pn-cool)"], [true, false])}<div class="chart-foot"><span class="legend"><i style="background:#0a84ff"></i>下载 <i style="background:var(--pn-cool);margin-left:8px"></i>上传</span><span>峰值 ${fmtRateLong(Math.max(...down))}</span></div></div>` +
      `<div class="sec">连接</div><div class="pc rows"><div class="r"><span>公网 IP</span><span>203.0.113.24</span></div><div class="r"><span>Wi-Fi</span><span>Studio-5G · 信号强（-48 dBm）</span></div><div class="r"><span>延迟</span><span>${16 + Math.round(Math.random() * 6)} ms</span></div></div>` +
      `<div class="sec">应用流量</div><div class="pc"><div class="rank-h two"><span>应用</span><span class="num">↓ 下载</span><span class="num">↑ 上传</span></div>${liveApps().slice(0, +SET.rank).map((a) => { const i = apps.indexOf(a); return rankRow(a, (flows[i][0] / max) * 100, [kb(flows[i][0]), kb(flows[i][1])]); }).join("")}</div>` +
      footer("采样 23 ms");
  }

  function musicPanel() {
    const t = tracks[S.track];
    const fmt = (s) => Math.floor(s / 60) + ":" + String(Math.floor(s % 60)).padStart(2, "0");
    const devices = [["speaker", "内置扬声器", S.vol + "%"], ["monitor", "外接显示器", ""], ["usb", "USB 音频", "100%"]];
    return header('<svg viewBox="0 0 24 24" fill="none" stroke="#0096d6" stroke-width="2" stroke-linecap="round"><path d="M4 10v4M8 6v12M12 3v18M16 7v10M20 10v4"/></svg>', "音乐频谱") +
      `<div class="mcard" style="background:linear-gradient(160deg, color-mix(in srgb, ${t.bar} 20%, var(--pn-card)) 0%, var(--pn-card) 100%)"><button class="expand" data-act="full" title="全屏频谱"><svg viewBox="0 0 24 24"><path d="M14 4h6v6M10 20H4v-6M20 4l-6 6M4 20l6-6"/></svg></button><div class="mtop"><div class="art" style="background:linear-gradient(135deg, ${t.from}, ${t.via} 55%, ${t.to})"></div><div class="meta"><b>${t.title}</b><span>${t.artist}</span><small>音乐播放器</small></div></div>` +
      `<div class="mbars">${levels.map(() => `<i style="background:${t.bar}"></i>`).join("")}</div>` +
      `<div class="prog"><em style="width:${(S.elapsed / t.len) * 100}%;background:${t.bar}"></em></div><div class="ptime"><span>${fmt(S.elapsed)}</span><span>-${fmt(t.len - S.elapsed)}</span></div>` +
      `<div class="mctl"><button data-act="prev" aria-label="上一首">${ICON.prev}</button><button class="big" data-act="toggle" aria-label="播放或暂停">${S.playing ? ICON.pause : ICON.play}</button><button data-act="next" aria-label="下一首">${ICON.next}</button></div></div>` +
      `<div class="sec">声音输出</div><div class="pc"><div class="vol"><svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M4 9h4l5-4v14l-5-4H4z"/></svg><input type="range" min="0" max="100" value="${S.vol}" aria-label="音量"><span>${S.vol}%</span></div>` +
      `<div style="height:0.5px;background:var(--pn-sep);margin:8px 0"></div>${devices.map(([ic, n, v], i) => `<div class="dev${i === S.device ? " sel" : ""}" data-dev="${i}"><span class="di">${svgIcon(ic)}</span><span>${n}</span><span>${i === S.device ? v : ""}</span></div>`).join("")}</div>` +
      `<div class="pf"><span><b data-act="settings">样式设置</b></span><span><b data-act="quit">退出</b></span></div>`;
  }

  // 圆环下面的电量：AirPods 这类分两行，上面左右耳、下面充电盒；其他设备一行百分比（和软件一致）
  const btText = (d) => d.ears ? `<b>L${d.ears[0]} R${d.ears[1]}</b><small class="box">盒 ${d.box}%</small>` : `<b>${d.level == null ? "—" : d.level + "%"}</b>`;
  function btPanel() {
    const on = S.bt.filter((d) => d.on), off = S.bt.filter((d) => !d.on);
    return header('<svg viewBox="0 0 24 24" fill="none" stroke="#0096d6" stroke-width="1.8" stroke-linecap="round"><rect x="6.5" y="2.5" width="11" height="19" rx="5.5"/><path stroke-width="1.4" d="M9.1 9.8L14.9 14.2 12 16.6V7.4l2.9 2.4L9.1 14.2" stroke-linejoin="round"/></svg>', "蓝牙") +
      `<div class="pc"><div class="bt-top">${on.map((d) => `<div class="bt-dev" data-bt="${S.bt.indexOf(d)}" title="点击断开"><div class="big">${ringSVG(btLevel(d) ?? 0, 58, 5, btLevel(d) == null ? "transparent" : batteryColor(btLevel(d)), "var(--pn-inset)")}<div class="g">${svgIcon(d.icon)}</div></div><small>${d.name}</small>${btText(d)}</div>`).join("") || '<div class="empty-bt">没有已连接的设备</div>'}</div></div>` +
      (off.length ? `<div class="sec">其他设备</div><div class="pc">${off.map((d) => `<div class="bt-other"><span class="di">${svgIcon(d.icon)}</span><span>${d.name}</span><button data-bt="${S.bt.indexOf(d)}">连接</button></div>`).join('<div style="height:8px"></div>')}</div>` : "") +
      `<div class="pf"><span>点设备连接 / 断开</span><span><b data-act="btsys">蓝牙设置</b><b data-act="quit">退出</b></span></div>`;
  }

  function renderPanel() {
    if (!open) return;
    const scroll = panel.scrollTop;
    panel.innerHTML = open === "music" ? musicPanel() : open === "net" ? netPanel() : open === "bt" ? btPanel() : metricPanel(open);
    panel.scrollTop = scroll;
  }

  function place(seg) {
    const r = seg.getBoundingClientRect();
    panel.style.left = clamp(r.left + r.width / 2 - 150, 8, window.innerWidth - 308) + "px";
    panel.style.top = r.bottom + 6 + "px";
  }

  function toggle(key, seg) {
    island.querySelectorAll(".seg").forEach((s) => s.classList.toggle("on", s === seg && open !== key));
    if (open === key) { open = null; panel.classList.remove("show"); return; }
    open = key;
    place(seg);
    renderPanel();
    panel.classList.add("show");
  }

  island.addEventListener("click", (e) => {
    if (islandDragged) return;   // 刚拖完胶囊，不当成点击
    const ctl = e.target.closest("[data-ctl]");
    if (ctl) {
      if (ctl.dataset.ctl === "toggle") { S.playing = !S.playing; S.pausedAt = Date.now(); }
      else { S.track = (S.track + (ctl.dataset.ctl === "next" ? 1 : tracks.length - 1)) % tracks.length; S.elapsed = 0; S.playing = true; }
      renderIsland(); renderPanel();
      return;
    }
    const seg = e.target.closest(".seg");
    if (seg) toggle(seg.dataset.p, seg);
  });
  document.addEventListener("click", (e) => {
    // 面板里的按钮点完会重画，被点的元素已经不在页面里了：按事件路径判断是不是点在面板上
    const path = e.composedPath();
    if (!open || path.includes(panel) || path.includes(island)) return;
    toggle(open, island.querySelector(`[data-p="${open}"]`));
  });
  panel.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (act === "settings") { const key = open; toggle(open, island.querySelector(`[data-p="${open}"]`)); openSettings(key); return; }
    if (act === "full") { toggle(open, island.querySelector(`[data-p="${open}"]`)); openVisualizer(); return; }
    if (act === "toggle") { S.playing = !S.playing; S.pausedAt = Date.now(); }
    if (act === "next" || act === "prev") { S.track = (S.track + (act === "next" ? 1 : tracks.length - 1)) % tracks.length; S.elapsed = 0; S.playing = true; }
    if (act === "diag") { toggle(open, island.querySelector(`[data-p="${open}"]`)); openSettings(null, "关于"); return; }
    if (act === "quit") { quitApp(); return; }
    if (act === "btsys") { toggle(open, island.querySelector(`[data-p="${open}"]`)); openSettings("bt"); return; }
    const kill = e.target.closest("[data-kill]")?.dataset.kill;
    if (kill) S.killed.add(kill);
    const eject = e.target.closest("[data-eject]")?.dataset.eject;
    if (eject !== undefined) { S.volumes.splice(+eject, 1); renderPanel(); showToast("已推出“备份盘”"); return; }
    const strategy = e.target.closest("[data-strategy]")?.dataset.strategy;
    if (strategy) S.strategy = strategy;
    const awake = e.target.closest("[data-awake]")?.dataset.awake;
    if (awake) { S.awake = awake; S.awakeUntil = { "30 分钟": 1800e3, "2 小时": 7200e3 }[awake] ? Date.now() + { "30 分钟": 1800e3, "2 小时": 7200e3 }[awake] : 0; }
    if (e.target.closest("[data-awscreen]")) S.awakeScreen = !S.awakeScreen;
    if (kill || strategy || awake || e.target.closest("[data-awscreen]")) { renderIsland(); renderPanel(); return; }
    const range = e.target.closest("[data-range]")?.dataset.range;
    if (range) S.range = range;
    const dev = e.target.closest("[data-dev]")?.dataset.dev;
    if (dev !== undefined) S.device = +dev;
    const bt = e.target.closest("[data-bt]")?.dataset.bt;
    if (bt !== undefined) S.bt[bt].on = !S.bt[bt].on;
    if (act || range || dev !== undefined || bt !== undefined) { renderIsland(); renderPanel(); }
  });
  // 风扇面板：曲线预设下拉（和软件一样在弹窗里直接切换）
  panel.addEventListener("change", (e) => {
    if (e.target.dataset.preset) { S.preset = e.target.value; renderPanel(); if (!win.classList.contains("closed")) renderSettings(); }
  });
  panel.addEventListener("input", (e) => {
    if (e.target.type !== "range") return;
    S.vol = +e.target.value;
    e.target.nextElementSibling.textContent = S.vol + "%";
    const sel = panel.querySelector(".dev.sel span:last-child");
    if (sel && S.device === 0) sel.textContent = S.vol + "%";
  });


  // ---------- 设置窗口：照软件里的 SettingsView 排版（侧栏 190、内容边距 22、卡片 12、行内图标 30）----------
  // 改动实时作用到菜单栏的灵动岛；“显示内容”用开关显示 / 隐藏，按住拖动调整顺序
  const win = h(`<section class="win settings closed" id="settings"><div class="tb"><span class="tl r"></span><span class="tl y"></span><span class="tl g"></span><span class="ttl">islet 设置</span></div><div class="wb"><nav class="side"></nav><div class="sep-v"></div><div class="content"></div></div></section>`);
  $("main.desktop").appendChild(win);
  // 侧栏分三组：灵动岛和它的各个模块 / 扩展功能、通用 / 关于（和软件的 SettingsPage.groups 一致）
  const PAGES = [["灵动岛", "#5e5ce6", '<rect x="3" y="8" width="18" height="8" rx="4"/>'],
    ["音乐", "#ff375f", '<path d="M5 10v4M9 7v10M13 4v16M17 8v8M21 11v2"/>'],
    ["系统指标", "#30d158", '<path d="M4 16a8 8 0 1 1 16 0"/><path d="M12 16l3-4"/>'],
    ["风扇", "#30b0c7", '<circle cx="12" cy="12" r="1.5"/><path d="M12 10.5C11 6 12 3 15 3s3 4-3 7.5zM13.5 12c4.5-1 7.5 0 7.5 3s-4 3-7.5-3zM12 13.5c1 4.5 0 7.5-3 7.5s-3-4 3-7.5zM10.5 12C6 13 3 12 3 9s4-3 7.5 3z"/>'],
    ["蓝牙电量", "#0a84ff", '<rect x="6.5" y="2.5" width="11" height="19" rx="5.5"/><path stroke-width="1.4" d="M9.1 9.8L14.9 14.2 12 16.6V7.4l2.9 2.4L9.1 14.2"/>'],
    ["扩展功能", "#bf5af2", '<path d="M10 4h4v3a2 2 0 1 0 0 0h3v4h-1a2 2 0 1 0 0 4h1v4h-4v-1a2 2 0 1 0-4 0v1H6v-4h1a2 2 0 1 0 0-4H6V7h4z" fill="#fff" stroke="none"/>'],
    ["通用", "#8e8e93", '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>'],
    ["关于", "#ff9f0a", '<circle cx="12" cy="12" r="8"/><path d="M12 11v5M12 8h.01"/>']];
  const PAGE_SEP = new Set([5, 7]);   // 这几页前面画分隔线
  // 图标：和软件的 IconTile、面板标题一样，只画彩色线条图标、不带底块（原来白色的填充改成同色）
  const tile = (color, path, size = 30) => `<span class="tile" style="color:${color};width:${size}px;height:${size}px"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${path.replaceAll("#fff", "currentColor")}</svg></span>`;
  const tg = (key) => `<span class="tg${SET[key] ? " on" : ""}" data-set="${key}"></span>`;
  const vis = (id) => `<span class="tg${SET.hidden.has(id) ? "" : " on"}" data-vis="${id}"></span>`;
  const sg = (key, opts, width) => `<div class="sg" style="width:${width}px">${opts.map((o) => `<button data-set="${key}" data-v="${o}" class="${SET[key] === o ? "sel" : ""}">${o}</button>`).join("")}</div>`;
  const row = (title, sub, ctl, icon) => `<div class="row">${icon || ""}<div class="st"><div>${title}</div>${sub ? `<small>${sub}</small>` : ""}</div>${ctl || ""}</div>`;
  const section = (title, body, extra = "") => `<div class="section"><div class="sh">${title}${extra}</div><div class="card">${body}</div></div>`;
  const join = (...rows) => rows.filter(Boolean).join('<div class="div"></div>');
  const btn = (title, attrs = "") => `<button class="pbtn" ${attrs}>${title}</button>`;
  const ITEMS = [
    ["music", "音乐", "#ff375f", '<path d="M5 10v4M9 7v10M13 4v16M17 8v8M21 11v2"/>'],
    ["cpu", "CPU", "#0a84ff", '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 3v3M15 3v3M9 18v3M15 18v3"/>'],
    ["gpu", "GPU", "#5e5ce6", '<path d="M12 3l9 5-9 5-9-5zM3 13l9 5 9-5"/>'],
    ["fps", "帧率", "#ff375f", '<path d="M4 17a8 8 0 1 1 16 0"/><path d="M12 17l4.5-5"/>'],
    ["mem", "内存", "#30d158", '<rect x="3" y="7" width="18" height="10" rx="2"/><path d="M7 7v10M12 7v10M17 7v10"/>'],
    ["disk", "磁盘", "#8e8e93", '<rect x="3" y="6" width="18" height="12" rx="2.5"/><path d="M7 14.5h.01"/>'],
    ["pwr", "功耗", "#ffb800", '<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>'],
    ["temp", "温度", "#ff9f0a", '<path d="M14 14.8V4a2 2 0 0 0-4 0v10.8a4 4 0 1 0 4 0z"/>'],
    ["fan", "风扇", "#30b0c7", '<circle cx="12" cy="12" r="1.5"/><path d="M12 10.5C11 6 12 3 15 3s3 4-3 7.5zM13.5 12c4.5-1 7.5 0 7.5 3s-4 3-7.5-3zM12 13.5c1 4.5 0 7.5-3 7.5s-3-4 3-7.5zM10.5 12C6 13 3 12 3 9s4-3 7.5 3z"/>'],
    ["net", "网速", "#0a84ff", '<path d="M7 20V4M3 8l4-4 4 4M17 4v16M13 16l4 4 4-4"/>'],
    ["bt", "蓝牙电量", "#0a84ff", '<rect x="6.5" y="2.5" width="11" height="19" rx="5.5"/><path stroke-width="1.4" d="M9.1 9.8L14.9 14.2 12 16.6V7.4l2.9 2.4L9.1 14.2"/>']];
  const itemInfo = Object.fromEntries(ITEMS.map(([id, name, color, path]) => [id, { name, color, path }]));
  const DEFAULT_SET = JSON.parse(JSON.stringify({ ...SET, hidden: [...SET.hidden] }));

  // 各模块自己的设置（和软件一样放在左侧单独的页里：音乐、系统指标里的网速 / 温度 / 帧率、风扇、蓝牙电量）
  function detailOf(id) {
    const d = (...rows) => join(...rows);
    switch (id) {
      case "music": return d(row("其他程序的声音", "", tg("other")), row("声音停止后收起", "", sg("collapse", ["立即", "10 秒", "不隐藏"], 220)),
        row("形状", "", sg("shape", ["竖条", "点阵"], 190)), row("颜色", "", sg("color", ["专辑色", "图标色", "白色"], 220)),
        row("封面旋转", "", tg("spin")), row("播放按钮", "", tg("buttons")),
        row("灵敏度", "", sg("sens", ["低", "标准", "高"], 190)), row("系统录音权限", "不录麦克风", btn("打开权限设置")));
      case "fan": return d(row("调速依据温度", "CPU/GPU 均温 · " + Math.round(S.temp) + "°C", sg("fanBasis", ["最高温度", "平均温度"], 200)),
        row("温度曲线", "预设：" + S.preset, btn("编辑", 'data-fan-edit="1"')), row("规则", "2 条 · 启用 2 条", btn("编辑", 'data-fan-edit="1"')),
        row("控制组件", "已安装，正常", btn("卸载")), row("退出时交还系统", "", '<small class="muted">始终开启</small>'));
      case "net": return d(row("显示方式", "自动：只显示较快的一方", sg("netMode", ["自动", "上传和下载"], 180)), row("单位", "", sg("netUnit", ["MB/s", "Mb/s"], 160)),
        row("流量统计每月起始日", "对齐运营商账单", `<select class="sel" data-month="1">${Array.from({ length: 28 }, (_, i) => `<option value="${i + 1}"${SET.monthStart === i + 1 ? " selected" : ""}>${i + 1} 日</option>`).join("")}</select>`),
        row("清零流量统计", "", btn("清零", 'data-clear="1"')));
      case "temp": return d(row("温度单位", "", sg("tempUnit", ["℃", "℉"], 120)));
      case "fps": return d(row("屏幕录制权限", "", btn("已授权")));
      case "bt": return d(row("低电量提醒", "", tg("btAlert")), row("提醒电量", "", sg("btLevel", ["10%", "20%", "30%"], 180)), row("提示音", "", tg("btSound")),
        row("测试通知", "", btn("发送测试通知", 'data-test="1"')));
      default: return "";
    }
  }
  const PAGE_OF = { music: "音乐", net: "系统指标", temp: "系统指标", fps: "系统指标", fan: "风扇", bt: "蓝牙电量" };
  const pageFns = {
    音乐: () => section("频谱", detailOf("music")),
    系统指标: () => section("网速", detailOf("net")) + section("温度", detailOf("temp")) + section("帧率", detailOf("fps")),
    风扇: () => section("调速", detailOf("fan")),
    蓝牙电量: () => section("提醒", detailOf("bt")),
  };

  // 显示内容的顺序：只存一份 SET.order。分体时三个模块按各自（指标取第一个）出现的先后排，指标连在一起；合并时按原样
  const MODULES = ["music", "metrics", "bt"];
  const modulesOf = (order) => order.reduce((a, id) => { const m = isModule(id) ? id : "metrics"; if (!a.includes(m)) a.push(m); return a; }, []);
  const metricsOf = (order) => order.filter((id) => !isModule(id));
  const flatten = (mods, mets) => mods.flatMap((m) => (m === "metrics" ? mets : [m]));
  const grouped = (order) => flatten(modulesOf(order), metricsOf(order));
  const SUBS = {};
  const METRICS_TILE = ["系统指标", "#30d158", '<path d="M4 16a8 8 0 1 1 16 0"/><path d="M12 16l3-4"/>'];
  // 一行：图标、名称（模块带说明），右侧是显示开关和拖动把手；grp 决定能和谁换位置
  function itemRow(id, grp, compact) {
    const it = id === "metrics" ? { name: METRICS_TILE[0], color: METRICS_TILE[1], path: METRICS_TILE[2] } : itemInfo[id];
    const on = id === "metrics" ? SET.metrics : !SET.hidden.has(id);
    const sw = id === "metrics" ? tg("metrics") : vis(id);
    return `<div class="item${on ? "" : " off"}${drag && drag.id === id ? " dragging" : ""}" data-item="${id}" data-grp="${grp}">${tile(it.color, it.path, compact ? 22 : 30)}` +
      `<span class="nm"${id === "metrics" ? ' data-mets="1"' : ""}><span>${it.name}${id === "metrics" ? `<i class="chev${SET.metsOpen ? " open" : ""}">›</i>` : ""}</span>` +
      `${id === "metrics" && !SET.metsOpen ? `<small>显示 ${metricsOf(SET.order).filter((x) => !SET.hidden.has(x)).length} 项</small>` : ""}</span>${sw}<span class="grip" title="按住拖动调整顺序"><svg viewBox="0 0 24 24"><path d="M5 8h14M5 12h14M5 16h14"/></svg></span></div>`;
  }
  function displayList() {
    if (SET.split) {
      // 分体：每张卡片是一个小胶囊；系统指标卡片里列出各项指标，只在卡片里排序
      return modulesOf(SET.order).map((m) => `<div class="card list">${itemRow(m, "mod", false)}` +
        (m === "metrics" && SET.metsOpen ? `<div class="mets${SET.metrics ? "" : " off"}">${metricsOf(SET.order).map((id) => '<div class="div"></div>' + itemRow(id, "met", true)).join("")}</div>` : "") + `</div>`).join("");
    }
    // 合并：一个平铺列表，音乐、蓝牙、各项指标任意排序；没有“系统指标”整组行，整组关着时在上面提示
    return (SET.metrics ? "" : '<p class="hint">系统指标已整组隐藏 · <a href="#" data-set="metrics">打开</a></p>') +
      `<div class="card list">${SET.order.map((id) => itemRow(id, "all", true)).join('<div class="div"></div>')}</div>`;
  }

  function islandPage() {
    return `` +
      section("胶囊", join(
        row("显示位置", "", `<div class="sg" style="width:140px"><button data-float="1" class="${SET.float ? "sel" : ""}">悬浮</button><button data-float="0" class="${SET.float ? "" : "sel"}">菜单栏</button></div>`, tile("#0a84ff", '<rect x="4" y="4" width="12" height="12" rx="2"/><rect x="8" y="8" width="12" height="12" rx="2"/>')),
        SET.float ? row("全屏时保持悬浮", "", tg("fullFloat"), tile("#0a84ff", '<path d="M4 9V4h5M20 15v5h-5M4 4l6 6M20 20l-6-6"/>')) : "",
        SET.float ? row("自由拖动", "", tg("freeDrag"), tile("#0a84ff", '<path d="M8 13V5.5a1.5 1.5 0 0 1 3 0V12M11 11.5V4a1.5 1.5 0 0 1 3 0v8M14 6a1.5 1.5 0 0 1 3 0v7M17 8.5a1.5 1.5 0 0 1 3 0V15a6 6 0 0 1-6 6h-1a6 6 0 0 1-5-2.7L5 14a1.5 1.5 0 0 1 2.5-1.7L8 13"/>')) : "",
        SET.float ? "" : row("始终在菜单栏最左侧", "关闭后按住 ⌘ 拖动", tg("leftmost"), tile("#30d158", '<path d="M9 3h6l-1 6 3 3H7l3-3zM12 12v9"/>')),
        row("胶囊形态", "",
          `<div class="sg" style="width:140px"><button data-split="1" class="${SET.split ? "sel" : ""}">分体</button><button data-split="0" class="${SET.split ? "" : "sel"}">合并</button></div>`,
          tile("#bf5af2", '<rect x="3" y="7" width="8" height="10" rx="3"/><rect x="13" y="7" width="8" height="10" rx="3"/>')),
        row("样式", SET.float ? "" : "「玻璃」仅在悬浮模式生效",
          `<div class="sg" style="width:200px">${["渐变", "黑色", "玻璃"].map((o) => o === "玻璃" && !SET.float ? `<button class="dis" disabled>${o}</button>` : `<button data-set="bg" data-v="${o}" class="${(SET.bg === "玻璃" && !SET.float ? "渐变" : SET.bg) === o ? "sel" : ""}">${o}</button>`).join("")}</div>`,
          tile("#ff9f0a", '<circle cx="12" cy="12" r="9"/><circle cx="8" cy="10" r="1"/><circle cx="12" cy="7.5" r="1"/><circle cx="16" cy="10" r="1"/>')))) +
      `<div class="section" data-list="1"><div class="sh">显示内容</div>${displayList()}` +

      `<div class="reset"><a href="#" data-reset="1">恢复默认显示和顺序</a></div></div>`;
  }
  // 显示器（和软件一致，以 27 寸 2K 屏为例）：开 HiDPI 后只列 islet 补上的 133%、143%、154%（200% 字太大不列），推荐 133%；
  // 原生和普通分辨率（放大显示、发虚）不列。没开 HiDPI 时只有原生一档，不显示卡片。档位 id：尺寸，HiDPI 的加 @2x
  const NATIVE = "2560×1440";
  const modes = () => SET.hidpi ? [["1920×1080@2x", "推荐"], ["1792×1008@2x", "更大文字"], ["1664×936@2x", "更大文字"]] : [];
  const scaleOf = (m) => Math.round(2560 / +m.split("×")[0] * 1000) / 10 + "%";
  const defaultMode = () => (SET.hidpi ? "1920×1080@2x" : NATIVE);
  const curMode = () => SET.mode || defaultMode();
  const modeSize = (m) => m.replace("@2x", "");
  // 显示器说明（和软件一致）：第一行“分辨率 模式 · 刷新率”；第二行没开 HiDPI 时说明开关作用，用 HiDPI 时说明实际按多大绘制
  function displaySubtitle() {
    const m = curMode(), hi = m.endsWith("@2x"), px = modeSize(m).split("×").map((n) => n * 2);
    const note = !SET.hidpi ? "开启 HiDPI 后文字更清晰，大小可调"
      : !hi ? (modeSize(m) !== NATIVE ? "普通分辨率，放大显示会发虚" : null)
      : px[0] < 2560 - 8 ? `按 ${px.join("×")} 绘制后放大显示，会发虚`
      : px[0] <= 2560 + 8 ? "按屏幕原生像素绘制，最清晰"
      : `文字更清晰，显卡负担稍高（按 ${px.join("×")} 绘制）`;
    return `${modeSize(m)} ${hi ? "HiDPI" : "普通"} · 60Hz` + (note ? "<br>" + note : "");
  }
  function extPage() {
    return section("鼠标滚动", join(
        row("平滑滚动", "", tg("smooth"), tile("#0a84ff", '<rect x="7" y="3" width="10" height="18" rx="5" fill="#fff" stroke="none"/><path d="M12 6.5v4" stroke="#0a84ff"/>')),
        SET.smooth ? row("滚动距离", "", sg("dist", ["短", "中", "长"], 170)) : "",
        SET.smooth ? row("平滑程度", "", sg("soft", ["低", "中", "高"], 170)) : "",
        SET.smooth ? row("反转滚动方向", "不影响触控板", tg("reverse")) : "")) +
      section("显示器", join(
        row("外接显示器 · 27 英寸", displaySubtitle(), `<span class="btns"><span class="muted" style="font-size:13px;color:var(--pn-text2)">HiDPI 支持</span>${tg("hidpi")}</span>`, tile("#64d2ff", '<rect x="3" y="4" width="18" height="12" rx="1.5"/><path d="M9 20h6M12 16v4"/>')),
        (modes().length ? `<div class="modes">${modes().map(([m, tag]) => `<span class="mode${m === curMode() ? " sel" : ""}" data-mode="${m}"><b>${modeSize(m)}</b><small>${tag}</small><i>${scaleOf(m)}</i></span>`).join("")}</div>` : "")));
  }
  // 各指标的默认阈值、可选阈值和单位（和软件的 AlertRule 一致）
  const RULE_KINDS = { CPU: [90, [50, 70, 80, 90, 95], "%"], GPU: [90, [50, 70, 80, 90, 95], "%"], 温度: [95, [70, 80, 85, 90, 95, 100], "°"],
    功耗: [60, [20, 30, 40, 60, 80, 100], " W"], 内存: [14, [8, 12, 14, 16, 20, 24, 32], " GB"] };
  const ruleLabel = (kind, v) => (kind === "温度" ? deg(v) : v + RULE_KINDS[kind][2]);
  const opts = (list, cur, label = (x) => x) => list.map((x) => `<option value="${x}"${x == cur ? " selected" : ""}>${label(x)}</option>`).join("");
  const ruleRow = (r, i) => `<div class="rule${r.on ? "" : " off"}"><span class="tg${r.on ? " on" : ""}" data-rule-on="${i}"></span>` +
    `<select class="sel" data-rule="${i}" data-k="kind">${opts(Object.keys(RULE_KINDS), r.kind)}</select><span>≥</span>` +
    `<select class="sel" data-rule="${i}" data-k="th">${opts(RULE_KINDS[r.kind][1], r.th, (x) => ruleLabel(r.kind, x))}</select><span>持续</span>` +
    `<select class="sel" data-rule="${i}" data-k="min">${opts([1, 3, 5, 10, 30], r.min, (x) => x + " 分钟")}</select>` +
    `<button class="del" data-rule-del="${i}" title="删除这条规则">✕</button></div>`;
  function generalPage() {
    return section("基本", join(
        row("登录时启动", "", tg("login"), tile("#30d158", '<path d="M12 3v8M7 6.5a7 7 0 1 0 10 0"/>')))) +
      section("提醒", join(row("提醒规则", "", btn("添加", 'data-rule-add="1"'), tile("#ff453a", '<path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 21h4" fill="#fff" stroke="none"/>')),
        ...SET.rules.map(ruleRow))) +
      section("数据", join(
        row("刷新频率", "越快越耗电", sg("rate", ["1 秒", "2 秒", "3 秒"], 170), tile("#0a84ff", '<path d="M20 12a8 8 0 1 1-2.3-5.7M20 4v4h-4"/>')),
        row("排行条数", "", sg("rank", ["3", "5", "8"], 170), tile("#32ade6", '<path d="M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01"/>')))) +
      section("重置", row("恢复默认设置", "", btn("恢复默认", 'data-reset-all="1"'), tile("#8e8e93", '<path d="M4 9a8 8 0 1 1 1 7M4 4v5h5"/>')));
  }
  let checking = false;
  function aboutPage() {
    return `<div class="about"><img src="icon-b1a28c54b977.png" alt=""><div><div><b>islet</b> <small>v1.4.3 (82)</small></div><div class="sub">菜单栏里的灵动岛</div></div></div>` +
      section("项目", row("Buerxzhang / islet", "GitHub 开源项目", `<span class="btns"><a class="pbtn" href="./">官网</a><a class="pbtn" href="https://github.com/Buerxzhang/islet" target="_blank" rel="noopener">GitHub</a><a class="pbtn" href="https://github.com/Buerxzhang/islet" target="_blank" rel="noopener">★ Star</a></span>`, tile("#1d1d1f", '<path d="M8 8l-4 4 4 4M16 8l4 4-4 4M14 5l-4 14"/>'))) +
      section("更新", join(
        row(checking ? "软件更新" : "已是最新版本", checking ? "正在查询 GitHub…" : "", btn(checking ? "检查中…" : "检查更新", 'data-check="1"'), tile("#0a84ff", '<path d="M20 12a8 8 0 1 1-2.3-5.7M20 4v4h-4"/>')),
        row("自动检查更新", "", tg("autoUpdate"), tile("#ff9f0a", '<path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 21h4" fill="#fff" stroke="none"/>')))) +
      section("诊断", row("自检通过，一切正常", "反馈时自动复制报告，粘贴即可", `<span class="btns">${btn("复制报告", 'data-copy="1"')}<a class="pbtn" href="https://github.com/Buerxzhang/islet/issues/new" target="_blank" rel="noopener">反馈问题</a></span>`, tile("#ff453a", '<path d="M6 4v5a4 4 0 0 0 8 0V4M10 13v2a5 5 0 0 0 10 0v-2"/><circle cx="20" cy="11" r="1.6"/>')));
  }

  // 页尾说明（和软件一致）：行里只放标题和控件，较长的解释、注意事项统一放在页面最下面
  const NOTES = {
    灵动岛: [["胶囊", "玻璃样式仅在悬浮模式下生效。"], ["显示内容", "至少要保留一项。想完全不显示灵动岛，可以只保留音乐（不放歌时就不显示），或按 ⌘Q 退出 islet。"]],
    音乐: [["频谱", "需要授权「系统录音」权限，只读取正在播放的声音来画频谱，不录麦克风。"], ["兼容性", "会自动识别「音乐」类软件；遇到不适配的软件，欢迎在「关于」页反馈。"]],
    系统指标: [["帧率", "是前台窗口所在屏幕每秒画面变化的次数，画面静止时会变低。"]],
    风扇: [["调速", "通过未公开的接口实现，系统升级后可能失效。转速有安全下限，退出 islet 或电脑睡眠时会交还系统。遇到异常，请把调速策略切回「自动」或卸载组件。"]],
    蓝牙电量: [["电量", "由系统读取蓝牙设备上报的电量。各设备的协议不同，部分设备可能读不到或不准。"]],
    扩展功能: [["HiDPI", "需要输入管理员密码写入系统配置，并且要显示器支持。打开后如果显示异常，请关掉它。"]],
  };
  const pageNotes = (page) => (NOTES[page] ? `<div class="pnotes">${NOTES[page].map(([t, x]) => `<p><b>「${t}」</b>${x}</p>`).join("")}</div>` : "");
  function renderSettings() {
    win.querySelector(".side").innerHTML = PAGES.map(([name, color, path], i) => (PAGE_SEP.has(i) ? '<div class="sep"></div>' : "") +
      `<div class="nav${SET.page === name ? " sel" : ""}" data-page="${name}">${tile(color, path, 24)}<span>${name}</span>${name === "关于" ? "<small>v1.4.3</small>" : ""}</div>`).join("");
    const content = win.querySelector(".content"), scroll = content.scrollTop;
    content.innerHTML = `<h3>${SET.page}</h3>` + { 灵动岛: islandPage, 扩展功能: extPage, 通用: generalPage, 关于: aboutPage, ...pageFns }[SET.page]() + pageNotes(SET.page);
    content.scrollTop = scroll;
  }
  // 设置窗口和软件一样固定 720 宽（不再跟着岛变宽）
  function fitSettings() {
    win.style.width = Math.min(720, desk.clientWidth - 40) + "px";
  }

  // 打开设置：从面板进来时直接到这一项所在的页（音乐、系统指标、风扇、蓝牙电量），其他到灵动岛页
  function openSettings(item, page = "灵动岛") {
    SET.page = (item && PAGE_OF[item]) || page;
    renderSettings();
    win.querySelector(".content").scrollTop = 0;
    openWin("settings");
    fitSettings();
  }

  document.documentElement.classList.add("pn-light");   // 面板和窗口统一浅色（和软件一致，没有主题设置）
  function applySettingChange() { renderSettings(); renderIsland(); if (typeof scheduleTick === "function") scheduleTick(); }
  win.addEventListener("click", (e) => {
    if (e.target.closest("[data-test]")) {   // 蓝牙：发一条示例通知到通知中心
      notes.unshift({ t: "键盘 Keys K2 电量低", b: "剩余 18%，记得充电（测试通知）", time: "刚刚" });
      togglePop("notif", $('[data-pop="notif"]'));
      return;
    }
    if (e.target.closest("[data-reset]")) {
      e.preventDefault();
      SET.order = [...DEFAULT_SET.order]; SET.hidden = new Set(DEFAULT_SET.hidden);
      applySettingChange();
      return;
    }
    const visId = e.target.closest("[data-vis]")?.dataset.vis;
    if (visId) { if (SET.hidden.has(visId)) SET.hidden.delete(visId); else SET.hidden.add(visId); applySettingChange(); return; }
    if (e.target.closest("[data-clear]")) { S.today = 0; S.month = 0; showToast("今日和本月的流量统计已清零"); renderPanel(); return; }
    const mode = e.target.closest("[data-mode]")?.dataset.mode;
    if (mode) { SET.mode = mode; renderSettings(); return; }
    if (e.target.closest("[data-fan-edit]")) { showToast("温度曲线和规则在软件里可以拖动编辑"); return; }
    if (e.target.closest("[data-rule-add]")) { SET.rules.push({ kind: "温度", th: 95, min: 1, on: true }); renderSettings(); return; }
    const ruleOn = e.target.closest("[data-rule-on]")?.dataset.ruleOn;
    if (ruleOn !== undefined) { SET.rules[+ruleOn].on = !SET.rules[+ruleOn].on; renderSettings(); return; }
    const del = e.target.closest("[data-rule-del]")?.dataset.ruleDel;
    if (del !== undefined) { SET.rules.splice(+del, 1); renderSettings(); return; }
    if (e.target.closest("[data-reset-all]")) {
      const d = JSON.parse(JSON.stringify(DEFAULT_SET));
      Object.assign(SET, d, { hidden: new Set(d.hidden), page: "通用" });
      S.awake = "关闭"; S.strategy = "自动";
      applySettingChange(); showToast("已恢复默认设置");
      return;
    }
    if (e.target.closest("[data-check]")) {
      checking = true; renderSettings();
      setTimeout(() => { checking = false; renderSettings(); showToast("已是最新版本"); }, 1200);
      return;
    }
    if (e.target.closest("[data-copy]")) {
      const report = "islet 1.4.3 (82) · 诊断报告（示例）\n机型：Mac（示例）\n系统：macOS 15\n传感器：8 个\n风扇：自动";
      navigator.clipboard?.writeText(report).catch(() => {});
      showToast("已复制诊断报告（示例），到 GitHub 粘贴即可");
      return;
    }
    if (dragMoved) return;   // 刚拖完松手，不当成点击
    if (e.target.closest("[data-mets]")) { SET.metsOpen = !SET.metsOpen; renderSettings(); return; }   // 系统指标卡片展开 / 收起
    const fl = e.target.closest("[data-float]");
    if (fl) { SET.float = fl.dataset.float === "1"; applySettingChange(); return; }   // 显示位置：悬浮 / 菜单栏
    const sp = e.target.closest("[data-split]");
    if (sp) { SET.split = sp.dataset.split === "1"; applySettingChange(); return; }
    const t = e.target.closest("[data-set],[data-page]");
    if (!t) return;
    if (t.tagName === "A") e.preventDefault();
    if (t.dataset.page) { SET.page = t.dataset.page; win.querySelector(".content").scrollTop = 0; }
    if (t.dataset.set) SET[t.dataset.set] = t.dataset.v ?? !SET[t.dataset.set];
    if (t.dataset.set === "hidpi") SET.mode = null;
    applySettingChange();
    renderPanel();
  });
  // 下拉框：流量统计起始日、提醒规则的指标
  win.addEventListener("change", (e) => {
    if (e.target.dataset.month) SET.monthStart = +e.target.value;
    if (e.target.dataset.rule !== undefined) {
      const r = SET.rules[+e.target.dataset.rule], k = e.target.dataset.k;
      if (k === "kind") { r.kind = e.target.value; r.th = RULE_KINDS[r.kind][0]; } else r[k] = +e.target.value;   // 换指标时阈值回到该指标的默认值
    }
    renderSettings();
  });

  // 拖动排序：按住任意一行拖，蓝线是松手后的位置；只在同组里换位置；拖出列表外松手取消
  let drag = null, dragMoved = false;
  win.addEventListener("pointerdown", (e) => {
    const rowEl = e.target.closest(".item");
    if (!rowEl || e.button !== 0 || e.target.closest(".tg")) return;   // 点开关不算拖动
    drag = { id: rowEl.dataset.item, sx: e.clientX, sy: e.clientY, started: false, rowEl };
    dragMoved = false;
  });
  window.addEventListener("pointermove", (e) => {
    if (!drag) return;
    if (!drag.started) {
      if (Math.hypot(e.clientX - drag.sx, e.clientY - drag.sy) < 4) return;
      drag.started = true; dragMoved = true;
      const list = win.querySelector("[data-list]"), r = drag.rowEl.getBoundingClientRect();
      drag.list = list;
      drag.ghost = drag.rowEl.cloneNode(true);
      drag.ghost.className = "item ghost";
      Object.assign(drag.ghost.style, { width: r.width + "px", left: r.left + "px", top: r.top + "px" });
      document.body.appendChild(drag.ghost);
      drag.oy = e.clientY - r.top;
      drag.rowEl.classList.add("dragging");
      drag.line = h('<div class="dropline"></div>');
      document.body.appendChild(drag.line);
    }
    drag.ghost.style.top = e.clientY - drag.oy + "px";
    // 落点：除被拖动项外，中线在手指上方的行数（“未显示”标题也算一行）
    const lr = drag.list.getBoundingClientRect();
    drag.inside = e.clientX > lr.left - 30 && e.clientX < lr.right + 30 && e.clientY > lr.top - 30 && e.clientY < lr.bottom + 30;
    // 落点只在同组里算：分体时模块和模块、指标和指标；合并时所有项
    const seq = [...drag.list.querySelectorAll(`.item[data-grp="${drag.rowEl.dataset.grp}"]:not(.dragging)`)];
    let index = seq.length;
    for (let i = 0; i < seq.length; i++) {
      const rr = seq[i].getBoundingClientRect();
      if (e.clientY < rr.top + rr.height / 2) { index = i; break; }
    }
    drag.index = index; drag.seq = seq;
    const ref = seq[index] ? seq[index].getBoundingClientRect() : seq[seq.length - 1].getBoundingClientRect();
    const y = seq[index] ? ref.top - 2 : ref.bottom + 1;
    const cr = drag.rowEl.getBoundingClientRect();
    Object.assign(drag.line.style, { left: cr.left + "px", width: cr.width + "px", top: y + "px", display: drag.inside ? "block" : "none" });
    drag.ghost.style.opacity = drag.inside ? 0.85 : 0.4;
  });
  window.addEventListener("pointerup", () => {
    if (!drag) return;
    const d = drag; drag = null;
    if (!d.started) return;
    d.ghost.remove(); d.line.remove();
    if (d.inside) {
      // 按落点重排同组的项；显示 / 隐藏只由开关管
      const ids = d.seq.map((el) => el.dataset.item);
      ids.splice(d.index, 0, d.id);
      const grp = d.rowEl.dataset.grp;
      SET.order = grp === "all" ? ids : grp === "mod" ? flatten(ids, metricsOf(SET.order)) : flatten(modulesOf(SET.order), ids);
    }
    applySettingChange();
    setTimeout(() => { dragMoved = false; }, 0);
  });
  settingsReady = true;

  // ---------- 桌面窗口：打开 / 关闭 / 拖动 / 放大 ----------
  let zTop = 10;
  const desk = $("main.desktop");
  // 窗口默认放在悬浮胶囊下面，不让胶囊盖住标题栏：悬浮时胶囊在视口 top 40、高 22（见 .island.float），下沿再留 10
  const winTop = () => (SET.float ? Math.max(12, 40 + 22 + 10 - desk.getBoundingClientRect().top) : 12);
  const LAYOUT = {   // 默认位置和大小（相对桌面区域）；底部给程序坞留 84
    // 关于：水平居中，垂直方向在胶囊下沿和程序坞之间居中
    about: (W, H) => { const t = winTop(), w = Math.min(700, W * 0.5), h = Math.min(760, H - t - 96); return { x: (W - w) / 2, y: t + Math.max(0, (H - t - 84 - h) / 2), w, h }; },
    // 设置：和软件一样 720×620；放在中间略偏右
    settings: (W, H) => { const t = winTop(), w = Math.min(720, W - 40), h = Math.min(620, H - t - 96);
      return { x: Math.min(W - w - 20, (W - w) / 2 + 60), y: t + Math.max(0, Math.min((H - t - 84 - h) / 2 + 20, H - t - 84 - h)), w, h }; },
    faq: (W, H) => { const y = Math.max(60, winTop()); return { x: W / 2 - 280, y, w: 560, h: Math.min(520, H - y - 100) }; },
    feature: (W, H) => { const y = Math.max(40, winTop()); return { x: W / 2 - 350, y, w: 700, h: H - y - 110 }; },
  };
  function focusWin(w) { w.style.zIndex = ++zTop; }
  function openWin(id) {
    const w = document.getElementById(id);
    if (!w) return;
    if (!w.dataset.placed) {
      const r = LAYOUT[id](desk.clientWidth, desk.clientHeight);
      Object.assign(w.style, { left: r.x + "px", top: r.y + "px", width: r.w + "px", height: r.h + "px" });
      w.dataset.placed = "1";
    }
    w.classList.remove("closed");
    focusWin(w);
  }
  desk.addEventListener("pointerdown", (e) => {
    const w = e.target.closest(".win");
    if (w) focusWin(w);
    const tb = e.target.closest(".win > .tb");
    if (!tb || e.target.closest(".tl") || w.classList.contains("max")) return;
    const sx = e.clientX, sy = e.clientY, ox = w.offsetLeft, oy = w.offsetTop;
    const move = (ev) => {
      w.style.left = clamp(ox + ev.clientX - sx, 80 - w.offsetWidth, desk.clientWidth - 80) + "px";
      w.style.top = clamp(oy + ev.clientY - sy, 0, desk.clientHeight - 60) + "px";
    };
    const up = () => { window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", up); };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  });
  desk.addEventListener("click", (e) => {
    const tl = e.target.closest(".tl");
    if (tl) {
      const w = tl.closest(".win");
      if (tl.classList.contains("g")) w.classList.toggle("max"); else w.classList.add("closed");
      return;
    }
    // 窗口里指向功能页的链接，在桌面上的窗口里打开
    const a = e.target.closest("a[href]");
    if (a && a.closest(".win") && !a.target) {
      const href = a.getAttribute("href");
      if (/^[\w-]+\.html$/.test(href)) { e.preventDefault(); openFeature(href); }
      else if (href === "./" || href === "index.html") { e.preventDefault(); openWin("about"); }
      else if (href === "#faq") { e.preventDefault(); openWin("faq"); }
    }
  });
  desk.addEventListener("dblclick", (e) => {
    const tb = e.target.closest(".win > .tb");
    if (tb && !e.target.closest(".tl")) tb.parentElement.classList.toggle("max");
  });

  // 功能页：取同目录下的页面，把正文放进“功能”窗口
  async function openFeature(href) {
    const w = document.getElementById("feature"), body = $(".wcontent", w);
    openWin("feature");
    body.innerHTML = '<div class="loading">正在打开…</div>';
    try {
      const doc = new DOMParser().parseFromString(await (await fetch(href)).text(), "text/html");
      const article = doc.querySelector("article");
      $(".ttl", w).textContent = doc.title.replace(/ - islet$/, "");
      body.innerHTML = article ? article.outerHTML : "";
      body.scrollTop = 0;
    } catch {
      location.href = href;
    }
  }

  // ---------- 平滑滚动（设置 › 扩展功能）：打开后，鼠标滚轮在桌面里的窗口和面板上会顺滑滚动 ----------
  // 只接管“一格一格”的鼠标滚轮（行模式，或整数且较大的位移）；触控板的细小连续位移不受影响
  const smoothState = new WeakMap();
  window.addEventListener("wheel", (e) => {
    if (!SET.smooth || e.ctrlKey) return;
    const mouseLike = e.deltaMode === 1 || (Math.abs(e.deltaY) >= 40 && Number.isInteger(e.deltaY));
    if (!mouseLike) return;
    const el = e.target.closest(".wcontent, .settings .content, .panel");
    if (!el || el.scrollHeight <= el.clientHeight) return;
    e.preventDefault();
    const dist = { 短: 60, 中: 110, 长: 180 }[SET.dist], dur = { 低: 140, 中: 280, 高: 460 }[SET.soft];
    const dir = Math.sign(e.deltaY) * (SET.reverse ? -1 : 1);
    const st = smoothState.get(el) || { target: el.scrollTop };
    if (!st.anim) st.target = el.scrollTop;
    st.target = clamp(st.target + dir * dist, 0, el.scrollHeight - el.clientHeight);
    st.from = el.scrollTop; st.start = performance.now();
    smoothState.set(el, st);
    if (st.anim) return;
    st.anim = true;
    const stepScroll = (now) => {
      const k = Math.min(1, (now - st.start) / dur), ease = 1 - Math.pow(1 - k, 3);
      el.scrollTop = st.from + (st.target - st.from) * ease;
      if (k < 1) requestAnimationFrame(stepScroll); else st.anim = false;
    };
    requestAnimationFrame(stepScroll);
  }, { passive: false });

  // ---------- 悬浮显示 + 自由拖动：按住胶囊拖到想放的位置 ----------
  let islandDrag = null, islandDragged = false;
  island.addEventListener("pointerdown", (e) => {
    if (!SET.float || !SET.freeDrag || e.button !== 0) return;
    const r = island.getBoundingClientRect();
    islandDrag = { dx: e.clientX - r.left, dy: e.clientY - r.top, sx: e.clientX, sy: e.clientY, moved: false };
  });
  window.addEventListener("pointermove", (e) => {
    if (!islandDrag) return;
    if (!islandDrag.moved && Math.hypot(e.clientX - islandDrag.sx, e.clientY - islandDrag.sy) < 4) return;
    islandDrag.moved = true;
    Object.assign(island.style, { left: e.clientX - islandDrag.dx + "px", top: e.clientY - islandDrag.dy + "px", transform: "none" });
  });
  window.addEventListener("pointerup", () => { if (islandDrag?.moved) { islandDragged = true; setTimeout(() => { islandDragged = false; }, 0); } islandDrag = null; });

  // ---------- 外部链接（下载、GitHub 等）一律在新标签页打开，桌面演示留在原处 ----------
  document.addEventListener("click", (e) => {
    const a = e.target.closest("a[href]");
    if (!a || e.defaultPrevented || e.metaKey || e.ctrlKey || e.shiftKey) return;
    const url = new URL(a.getAttribute("href"), location.href);
    if (url.origin === location.origin) return;
    e.preventDefault();
    window.open(url.href, "_blank", "noopener");
  });

  // ---------- 退出 / 重新打开 islet（演示） ----------
  function quitApp() {
    if (open) toggle(open, island.querySelector(`[data-p="${open}"]`));
    closeVisualizer();
    S.quit = true;
    mount.style.display = "none";
    island.classList.remove("float");
    win.classList.add("closed");
    dockEl.querySelector('[data-open="about"]').classList.remove("run");
    showToast("islet 已退出 · 点程序坞里的 islet 重新打开");
  }
  function launchApp() {
    if (!S.quit) return false;
    S.quit = false;
    mount.style.display = "";
    renderIsland();
    dockEl.querySelector('[data-open="about"]').classList.add("run");
    return true;
  }
  function showToast(text) {
    const t = h(`<div class="toast">${text}</div>`);
    root.appendChild(t);
    requestAnimationFrame(() => t.classList.add("show"));
    setTimeout(() => { t.classList.remove("show"); setTimeout(() => t.remove(), 300); }, 2600);
  }

  // ---------- 灵动岛右键菜单（和软件一致）：隐藏点到的指标 / 模块、显示内容、分体 / 合并胶囊、悬浮显示 / 在菜单栏显示、设置、关于、退出 ----------
  // 只剩一项时不许再隐藏；岛上只剩指标时，“系统指标”模块也不许关，免得胶囊整个消失、连右键都点不到
  const ctx = h('<div class="ctxmenu"></div>');
  root.appendChild(ctx);
  const moduleName = { music: "音乐", metrics: "系统指标", bt: "蓝牙电量" };
  const nameOf = (id) => moduleName[id] || itemInfo[id].name;
  island.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    if (open) toggle(open, island.querySelector(`[data-p="${open}"]`));
    const at = e.target.closest(".seg")?.dataset.p;
    const shown = SET.order.filter(onIsland), lastOne = shown.length <= 1;
    const metricsOnly = shown.length > 0 && shown.every((id) => !isModule(id));
    const check = (on) => `<i>${on ? "✓" : ""}</i>`;
    const item = (m, label, { on = false, off = false, id = "", kbd = "" } = {}) =>
      `<div class="${off ? "dis" : ""}" ${off ? "" : `data-m="${m}"`} ${id ? `data-id="${id}"` : ""}>${check(on)}${label}${kbd ? `<kbd>${kbd}</kbd>` : ""}</div>`;
    let html = `<div class="dis"><i></i>islet 1.4.3</div><hr>`;
    if (at && shown.includes(at)) {
      const name = nameOf(at);
      html += item("vis", isModule(at) ? `隐藏${name}模块` : /^[A-Za-z]/.test(name) ? `隐藏 ${name} 指标` : `隐藏${name}指标`, { off: lastOne, id: at });
      if (!isModule(at)) html += item("vis", "隐藏系统指标模块", { off: metricsOnly, id: "metrics" });
    }
    const sub = `<div class="hd">模块</div>` +
      ["music", "metrics", "bt"].map((id) => {
        const on = id === "metrics" ? SET.metrics : shown.includes(id);
        return item("vis", moduleName[id], { on, off: on && (id === "metrics" ? metricsOnly : lastOne), id });
      }).join("") +
      `<hr><div class="hd">系统指标里的指标</div>` +
      SET.order.filter((id) => !isModule(id)).map((id) => item("vis", itemInfo[id].name, { on: !SET.hidden.has(id), off: !SET.metrics || (shown.includes(id) && lastOne), id })).join("");
    html += `<div class="has-sub"><i></i>显示内容<kbd>›</kbd><div class="sub">${sub}</div></div>` +
      item("split", SET.split ? "合并胶囊" : "分体胶囊") + item("float", SET.float ? "在菜单栏显示" : "悬浮显示") + `<hr>` +
      item("settings", "设置…", { kbd: "⌘," }) + item("about", "关于 islet") + `<hr>` + item("quit", "退出 islet", { kbd: "⌘Q" });
    ctx.innerHTML = html;
    const r = island.getBoundingClientRect();
    const left = clamp(e.clientX, 8, window.innerWidth - 220);
    ctx.style.left = left + "px";
    ctx.style.top = (SET.float ? e.clientY : r.bottom + 5) + "px";
    ctx.classList.toggle("flip", left + 440 > window.innerWidth);   // 右边放不下时子菜单往左开
    ctx.classList.add("show");
  });
  ctx.addEventListener("click", (e) => {
    const el = e.target.closest("[data-m]"), m = el?.dataset.m;
    if (!m) return;
    ctx.classList.remove("show");
    if (m === "settings") openSettings(null, "灵动岛");
    if (m === "about") openSettings(null, "关于");
    if (m === "quit") quitApp();
    if (m === "vis") {
      const id = el.dataset.id;
      if (id === "metrics") SET.metrics = !SET.metrics;
      else if (SET.hidden.has(id)) SET.hidden.delete(id);   // 隐藏的项留在原位，再显示时回到原来的位置
      else SET.hidden.add(id);
    }
    if (["float", "split"].includes(m)) SET[m] = !SET[m];
    if (["vis", "float", "split"].includes(m)) { renderIsland(); if (!win.classList.contains("closed")) renderSettings(); }
  });
  document.addEventListener("pointerdown", (e) => { if (!e.composedPath().includes(ctx)) ctx.classList.remove("show"); });

  // ---------- 菜单栏：功能下拉、常见问题、声音、通知 ----------
  const menu = $(".mmenu");
  $(".mmenu > a").addEventListener("click", (e) => { e.preventDefault(); menu.classList.toggle("open"); });
  $(".mmenu .drop").addEventListener("click", (e) => {
    const a = e.target.closest("a[href]");
    if (!a) return;
    e.preventDefault();
    menu.classList.remove("open");
    const href = a.getAttribute("href");
    if (href === "#features") { openWin("about"); $("#features").scrollIntoView({ behavior: "smooth" }); } else openFeature(href);
  });
  root.addEventListener("click", (e) => {
    const a = e.target.closest("[data-win]");
    if (a && a.closest("header")) { e.preventDefault(); openWin(a.dataset.win); }
    if (!e.composedPath().includes(menu)) menu.classList.remove("open");
  });

  const pops = {
    sound: h('<div class="pop" id="pop-sound"></div>'),
    notif: h('<div class="pop" id="pop-notif"></div>'),
  };
  Object.values(pops).forEach((p) => root.appendChild(p));
  // 低电量：设备本身（耳机取较低的一边）和充电盒分开提醒
  const KIND = { keyboard: "键盘", mouse: "鼠标", headphones: "耳机", earbuds: "耳机", pad: "手柄", trackpad: "触控板" };
  const lowNotes = () => !SET.btAlert ? [] : S.bt.filter((d) => d.on).flatMap((d) => [
    [btLevel(d), d.name], [d.box, d.name + " 充电盒"],
  ].filter(([v]) => v != null && v <= parseInt(SET.btLevel))
    .map(([v, name]) => ({ t: `${KIND[d.icon] || "设备"} ${name} 电量低`, b: `剩余 ${v}%，记得充电`, time: "刚刚", low: true })));
  let notes = [
    { t: "CPU 温度持续偏高", b: "CPU 温度已高于 85° 超过 3 分钟", time: "12 分钟前" },
    { t: "已保持唤醒 2 小时", b: "保持唤醒已结束，电脑会照常睡眠", time: "1 小时前" },
  ];
  function renderPop(key) {
    if (key === "sound") {
      const devices = [["speaker", "内置扬声器"], ["monitor", "外接显示器"], ["earbuds", "AirPods Pro"]];
      pops.sound.innerHTML = `<h4>声音</h4><div class="pc"><div class="vol"><svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M4 9h4l5-4v14l-5-4H4z"/></svg><input type="range" min="0" max="100" value="${S.vol}" aria-label="音量"><span>${S.vol}%</span></div></div>` +
        `<div class="sec">输出</div><div class="pc">${devices.map(([ic, n], i) => `<div class="dev${i === S.device ? " sel" : ""}" data-dev="${i}"><span class="di">${svgIcon(ic)}</span><span>${n}</span><span></span></div>`).join("")}</div>`;
    } else {
      const all = [...(notesCleared ? [] : lowNotes()), ...notes];
      pops.notif.innerHTML = `<h4>通知</h4>` + (all.length ? all.map((n) => `<div class="note"><img src="icon-b1a28c54b977.png" alt=""><div><b>${n.t}</b><span>${n.b}</span></div><time>${n.time}</time></div>`).join("") + '<button class="clear">全部清除</button>' : '<div class="empty">没有新通知</div>');
    }
  }
  let openPop = null;
  function togglePop(key, btn) {
    Object.values(pops).forEach((p) => p.classList.remove("show"));
    root.querySelectorAll(".mright .mi").forEach((b) => b.classList.remove("open"));
    if (openPop === key) { openPop = null; return; }
    openPop = key;
    renderPop(key);
    const r = btn.getBoundingClientRect();
    pops[key].style.left = clamp(r.right - 320, 8, window.innerWidth - 328) + "px";
    pops[key].classList.add("show");
    btn.classList.add("open");
  }
  root.querySelectorAll(".mright [data-pop]").forEach((b) => b.addEventListener("click", (e) => { e.stopPropagation(); togglePop(b.dataset.pop, b); }));
  document.addEventListener("click", (e) => {
    if (openPop && !e.composedPath().includes(pops[openPop])) togglePop(openPop, $(`[data-pop="${openPop}"]`));
  });
  pops.sound.addEventListener("input", (e) => { S.vol = +e.target.value; e.target.nextElementSibling.textContent = S.vol + "%"; });
  pops.sound.addEventListener("click", (e) => { const d = e.target.closest("[data-dev]"); if (d) { S.device = +d.dataset.dev; renderPop("sound"); } });
  let notesCleared = false;
  pops.notif.addEventListener("click", (e) => { if (e.target.closest(".clear")) { notes = []; notesCleared = true; renderPop("notif"); } });

  // ---------- 程序坞：灵动岛的各项，点开设置里对应的那一项；islet 打开“关于” ----------
  const g = (a, b) => `linear-gradient(160deg, ${a}, ${b})`;
  // 和设置里的图标同一种样式：上浅下深的单色渐变，没有高光和投影
  const tileBg = (hex) => `linear-gradient(180deg, color-mix(in srgb, ${hex} 85%, #fff), ${hex})`;
  const dockEl = $(".dock");
  // 程序坞只放几个“应用”，像网站导航：岛上的各项已经能直接点开，这里不再重复
  const DOCK = [
    { tip: "islet", open: "about", img: true },
    { tip: "islet 设置", page: "灵动岛", color: "#8e8e93", path: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>' },
    { tip: "扩展功能：平滑滚动、HiDPI", page: "扩展功能", color: "#bf5af2", path: '<path d="M10 4h4v3a2 2 0 1 0 0 0h3v4h-1a2 2 0 1 0 0 4h1v4h-4v-1a2 2 0 1 0-4 0v1H6v-4h1a2 2 0 1 0 0-4H6V7h4z" fill="#fff" stroke="none"/>' },
    { tip: "常见问题", open: "faq", color: "#ff9f0a", path: '<circle cx="12" cy="12" r="8.5"/><path d="M9.6 9.4a2.5 2.5 0 1 1 3.6 2.3c-.8.4-1.2.9-1.2 1.8M12 16.8h.01"/>' },
    "gap",
    { tip: "GitHub 源码", href: "https://github.com/Buerxzhang/islet", color: "#1d1d1f", path: '<path d="M8 8l-4 4 4 4M16 8l4 4-4 4M14 5l-4 14"/>' },
    { tip: "下载 islet", href: "https://github.com/Buerxzhang/islet/releases/latest", color: "#30d158", path: '<path d="M12 4v11M7.5 10.5L12 15l4.5-4.5M5 19h14"/>' },
  ];
  dockEl.innerHTML = DOCK.map((d) => d === "gap" ? '<span class="gap"></span>'
    : `<div class="app${d.img ? " run" : ""}"${d.open ? ` data-open="${d.open}"` : ""}${d.page ? ` data-page="${d.page}"` : ""}${d.href ? ` data-href="${d.href}"` : ""}>` +
      (d.img ? '<img class="ic" src="icon-b1a28c54b977.png" alt="islet">' : `<div class="ic" style="background:${tileBg(d.color)}"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${d.path}</svg></div>`) +
      `<span class="tip">${d.tip}</span></div>`).join("");
  const dockApps = [...dockEl.querySelectorAll(".app")];

  // 放大：每帧把尺寸往目标值靠一点（缓动），目标按鼠标到各图标“静止时”中心的距离算（钟形曲线）。
  // 用静止时的位置计算，图标变大挤开两边时不会反过来影响计算，所以不会抖。
  const BASE = 46, MAX = 64, RANGE = 120;
  let rest = [], mouseX = null, frame = 0;
  const size = dockApps.map(() => BASE);
  function measureRest() {
    const center = dockEl.getBoundingClientRect().left + dockEl.offsetWidth / 2;
    rest = dockApps.map((a) => { const r = a.getBoundingClientRect(); return r.left + r.width / 2 - center; });
  }
  function step() {
    const center = dockEl.getBoundingClientRect().left + dockEl.offsetWidth / 2;
    let moving = false;
    dockApps.forEach((a, i) => {
      const d = mouseX === null ? Infinity : mouseX - center - rest[i];
      const target = BASE + (MAX - BASE) * Math.exp(-(d * d) / (2 * (RANGE / 2.2) ** 2));
      size[i] += (target - size[i]) * 0.22;
      if (Math.abs(target - size[i]) > 0.15) moving = true; else size[i] = target;
      a.style.setProperty("--s", size[i].toFixed(2) + "px");
    });
    frame = moving ? requestAnimationFrame(step) : 0;
  }
  const kick = () => { if (!frame) frame = requestAnimationFrame(step); };
  measureRest();
  window.addEventListener("resize", () => { if (mouseX === null) measureRest(); });
  dockEl.addEventListener("mouseenter", () => { if (size.every((v) => v === BASE)) measureRest(); });
  dockEl.addEventListener("mousemove", (e) => { mouseX = e.clientX; kick(); });
  dockEl.addEventListener("mouseleave", () => { mouseX = null; kick(); });
  dockEl.addEventListener("click", (e) => {
    const a = e.target.closest(".app");
    if (!a) return;
    a.classList.remove("bounce"); void a.offsetWidth; a.classList.add("bounce");
    if (a.dataset.open === "about" && launchApp()) { openWin("about"); return; }
    if (a.dataset.href) { window.open(a.dataset.href, "_blank", "noopener"); return; }
    if (a.dataset.page) openSettings(null, a.dataset.page);
    else if (a.dataset.item) openSettings(a.dataset.item); else if (a.dataset.open) openWin(a.dataset.open);
  });

  openWin("about");

  // ---------- 每秒更新 ----------
  function tick() {
    S.cpu = walk(S.cpu, 8, 6, 64); S.gpu = walk(S.gpu, 8, 8, 70); S.mem = walk(S.mem, 0.2, 9.4, 11.2);
    S.pwr = walk(S.pwr, 4, 9, 34); S.temp = walk(S.temp, 1.5, 46, 64); S.fan = clamp(1000 + (S.temp - 52) * 60 + (Math.random() - 0.5) * 20, 1000, 2400);
    S.down = clamp(walk(S.down, 60, 2, 900) * (Math.random() < 0.06 ? 4 : 1), 2, 2600); S.up = walk(S.up, 3, 0.3, 40);
    S.diskRead = clamp(walk(S.diskRead, 3, 0, 40) * (Math.random() < 0.05 ? 5 : 1), 0, 180); S.diskWrite = walk(S.diskWrite, 1.5, 0, 20);
    S.fps = clamp(walk(S.fps, 14, 40, 120), 30, 120);
    const secs = { "1 秒": 1, "2 秒": 2, "3 秒": 3 }[SET.rate];
    S.today += (S.down + S.up) * secs; S.month += (S.down + S.up) * secs;
    const push = (k, v) => { S.hist[k].push(v); S.hist[k].shift(); };
    push("cpu", S.cpu); push("gpu", S.gpu); push("mem", S.mem / 16 * 100); push("pwr", S.pwr); push("fan", S.fan); push("down", S.down); push("up", S.up);
    push("disk", S.diskRead + S.diskWrite); push("temp", S.temp); push("fps", S.fps);
    if (S.playing && SET.rate === "1 秒") { S.elapsed += 1; if (S.elapsed >= tracks[S.track].len) { S.track = (S.track + 1) % tracks.length; S.elapsed = 0; } }
    syncVisualizer();
    renderIsland();
    // 正在拖音量时不重画音乐面板，免得滑块被打断
    if (open && !(open === "music" && document.activeElement?.type === "range")) renderPanel();
  }

  renderIsland();
  requestAnimationFrame(animate);
  // 刷新频率：设置里选 1 / 2 / 3 秒；播放进度仍按真实时间走
  let tickTimer = 0, tickRate = "";
  function scheduleTick() {
    if (tickRate === SET.rate) return;
    tickRate = SET.rate;
    clearInterval(tickTimer);
    tickTimer = setInterval(tick, { "1 秒": 1, "2 秒": 2, "3 秒": 3 }[SET.rate] * 1000);
  }
  scheduleTick();
  setInterval(() => { scheduleTick(); if (S.playing && SET.rate !== "1 秒") { S.elapsed = Math.min(S.elapsed + 1, tracks[S.track].len - 1); syncVisualizer(); } }, 1000);
})();
