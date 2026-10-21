/* ArchoeraMusic 宣传页脚本
 * Copyright (C) 2026 Archoera && BetaStudio2
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * 纯静态、零依赖。开屏动效与源码的对应关系：
 *   - 入场 1000ms，逐字延迟 38ms、单字 420ms → splash_screen_widgets.dart
 *   - 1.9s 后 550ms 淡出（easeInCubic / scale .98 / 上移 3%）→ bootstrap.dart
 * 这里只负责挂载动画类、计时与滚动编排；曲线和时长都在 CSS 里，便于对照源码。
 */

(function () {
  "use strict";

  var doc = document;
  var html = doc.documentElement;
  var body = doc.body;

  html.classList.add("js-reveal");

  var motionQuery = window.matchMedia
    ? window.matchMedia("(prefers-reduced-motion: reduce)")
    : { matches: false };

  var reduceMotion = motionQuery.matches;

  /* ── 开屏 ──────────────────────────────────────────────────────────── */

  var full = doc.getElementById("splash");
  var stageFrame = doc.getElementById("stage-frame");
  var stage = doc.getElementById("stage");

  var FULL_HOLD_MS = 1900;
  var DISMISS_MS = 550;

  var engine = readEngine();
  var splashTimer = 0;
  var hideTimer = 0;

  function readEngine() {
    try {
      return window.localStorage.getItem("archoera:engine") === "eraudio"
        ? "eraudio"
        : "stable";
    } catch (err) {
      return "stable";
    }
  }

  function writeEngine(next) {
    try {
      window.localStorage.setItem("archoera:engine", next);
    } catch (err) {
      /* 隐私模式下 localStorage 可能不可用，忽略即可 */
    }
  }

  // 把字标拆成逐字 span（对应 Flutter 的 _StaggeredText / _StaggeredChar）
  function splitBrand(root) {
    if (!root) return;
    var brand = root.querySelector(".splash-brand");
    if (!brand || brand.getAttribute("data-split") === "1") return;
    var text = brand.getAttribute("data-text") || brand.textContent || "";
    brand.textContent = "";
    Array.prototype.forEach.call(text, function (ch, i) {
      var span = doc.createElement("span");
      span.className = "char";
      span.style.setProperty("--i", String(i));
      span.textContent = ch;
      brand.appendChild(span);
    });
    brand.setAttribute("data-split", "1");
  }

  // 页内演示直接克隆整屏开屏，保证两处结构永远一致
  function buildStage() {
    if (!full || !stageFrame) return;
    var source = full.querySelector(".splash-screen");
    if (!source) return;
    var clone = source.cloneNode(true);
    clone.classList.remove("is-playing", "is-static", "engine-on");
    clone.removeAttribute("style");
    stageFrame.appendChild(clone);
  }

  function play(screen, options) {
    if (!screen) return;
    var speed = options && options.speed ? options.speed : 1;
    var which = (options && options.engine) || "stable";

    screen.classList.remove("is-playing");
    screen.classList.toggle("engine-on", which === "eraudio");
    screen.style.setProperty("--t", String(speed));
    void screen.offsetWidth;
    screen.classList.add("is-playing");
  }

  function markReady() {
    body.classList.add("is-ready");
  }

  function dismiss(forceInstant) {
    if (!full || !full.classList.contains("is-active")) return;
    if (full.classList.contains("is-dismissing")) return;

    window.clearTimeout(splashTimer);

    if (forceInstant || reduceMotion) {
      hideSplash();
      return;
    }

    full.classList.add("is-dismissing");
    markReady();
    hideTimer = window.setTimeout(hideSplash, DISMISS_MS + 60);
  }

  function hideSplash() {
    if (!full) return;
    window.clearTimeout(hideTimer);
    full.classList.remove("is-active", "is-dismissing");
    full.setAttribute("aria-hidden", "true");
    markReady();
  }

  function showSplash() {
    if (!full) return;
    window.clearTimeout(splashTimer);
    window.clearTimeout(hideTimer);

    body.classList.remove("is-ready");

    var screen = full.querySelector(".splash-screen");
    full.classList.remove("is-dismissing");
    full.classList.add("is-active");
    full.setAttribute("aria-hidden", "false");

    // 减少动态效果时 CSS 会把入场压到 1ms，直接呈现终态
    play(screen, { engine: engine, speed: 1 });

    splashTimer = window.setTimeout(function () {
      dismiss(false);
    }, reduceMotion ? 700 : FULL_HOLD_MS);
  }

  function playStage() {
    if (!stageFrame) return;
    var screen = stageFrame.querySelector(".splash-screen");
    var slow = doc.querySelector("[data-slowmo]");
    play(screen, {
      engine: engine,
      speed: slow && slow.checked ? 2 : 1,
    });
  }

  function setEngine(next, replay) {
    engine = next;
    writeEngine(next);
    Array.prototype.forEach.call(
      doc.querySelectorAll("[data-engine]"),
      function (btn) {
        var active = btn.getAttribute("data-engine") === next;
        btn.classList.toggle("is-active", active);
        btn.setAttribute("aria-pressed", String(active));
      }
    );
    if (replay) playStage();
  }

  splitBrand(full);
  buildStage();

  Array.prototype.forEach.call(
    doc.querySelectorAll("[data-replay-splash]"),
    function (btn) {
      btn.addEventListener("click", function () {
        closeMenu();
        showSplash();
      });
    }
  );

  var stageReplay = doc.querySelector("[data-stage-replay]");
  if (stageReplay) stageReplay.addEventListener("click", playStage);

  var stagePlay = doc.querySelector("[data-stage-play]");
  if (stagePlay) stagePlay.addEventListener("click", playStage);

  var slowmo = doc.querySelector("[data-slowmo]");
  if (slowmo) slowmo.addEventListener("change", playStage);

  Array.prototype.forEach.call(
    doc.querySelectorAll("[data-engine]"),
    function (btn) {
      btn.addEventListener("click", function () {
        setEngine(btn.getAttribute("data-engine"), true);
      });
    }
  );

  if (full) {
    // 开屏期间点击或按键可提前跳过
    full.addEventListener("click", function () {
      dismiss(false);
    });
    doc.addEventListener("keydown", function (event) {
      if (!full.classList.contains("is-active")) return;
      if (event.key === "Escape" || event.key === " " || event.key === "Enter") {
        event.preventDefault();
        dismiss(false);
      }
    });
  }

  /* ── 顶栏 / 进度 / 移动菜单 ────────────────────────────────────────── */

  var header = doc.querySelector(".site-header");
  var progress = doc.querySelector(".scroll-progress span");
  var heroWindow = doc.querySelector("[data-parallax]");
  var heroVisual = doc.getElementById("hero-visual");
  var cinema = doc.getElementById("cinema");
  var cinemaMedia = doc.querySelector("[data-cinema-media]");
  var heroSection = doc.getElementById("hero");
  var galleryProgress = doc.querySelector("[data-gallery-progress]");
  var galleryCount = doc.querySelector("[data-gallery-count]");

  var navLinks = Array.prototype.slice.call(
    doc.querySelectorAll("[data-nav]")
  );

  var sections = navLinks
    .map(function (link) {
      return doc.getElementById(link.getAttribute("data-nav"));
    })
    .filter(Boolean);

  var menuToggle = doc.querySelector(".menu-toggle");
  var mobileMenu = doc.getElementById("mobile-menu");

  function closeMenu() {
    if (!menuToggle || !mobileMenu) return;
    menuToggle.setAttribute("aria-expanded", "false");
    mobileMenu.classList.remove("is-open");
    mobileMenu.setAttribute("aria-hidden", "true");
    body.classList.remove("menu-open");
  }

  function openMenu() {
    if (!menuToggle || !mobileMenu) return;
    menuToggle.setAttribute("aria-expanded", "true");
    mobileMenu.classList.add("is-open");
    mobileMenu.setAttribute("aria-hidden", "false");
    body.classList.add("menu-open");
  }

  if (menuToggle && mobileMenu) {
    menuToggle.addEventListener("click", function () {
      if (menuToggle.getAttribute("aria-expanded") === "true") {
        closeMenu();
      } else {
        openMenu();
      }
    });
    mobileMenu.addEventListener("click", function (event) {
      if (event.target.closest("a")) closeMenu();
    });
    doc.addEventListener("keydown", function (event) {
      if (event.key === "Escape") closeMenu();
    });
  }

  /* ── 滚动状态 ──────────────────────────────────────────────────────── */

  var ticking = false;

  function onFrame() {
    ticking = false;
    var y = window.scrollY || window.pageYOffset;
    var docHeight = doc.documentElement.scrollHeight - window.innerHeight;

    if (header) header.classList.toggle("is-scrolled", y > 8);

    if (progress) {
      var p = docHeight > 0 ? Math.min(y / docHeight, 1) : 0;
      progress.style.transform = "scaleX(" + p.toFixed(4) + ")";
    }

    if (heroWindow && !reduceMotion && window.innerWidth > 1024) {
      var offset = Math.min(y * 0.06, 70);
      heroWindow.style.setProperty("--py", offset.toFixed(1) + "px");

      if (heroSection) {
        var hp = Math.min(Math.max(y / (heroSection.offsetHeight * 0.8), 0), 1);
        heroWindow.style.setProperty("--hero-scale", (1 - 0.05 * hp).toFixed(4));
        heroWindow.style.setProperty("--hero-opacity", (1 - 0.5 * hp).toFixed(3));
      }
    }

    if (cinema && cinemaMedia && !reduceMotion) {
      var rect = cinema.getBoundingClientRect();
      var span = cinema.offsetHeight - window.innerHeight;
      var p = span > 0 ? Math.min(Math.max(-rect.top / span, 0), 1) : 0;
      cinemaMedia.style.setProperty(
        "--cinema-scale",
        (1.06 - 0.06 * p).toFixed(4)
      );
    }
  }

  function onScroll() {
    if (ticking) return;
    ticking = true;
    window.requestAnimationFrame(onFrame);
  }

  window.addEventListener("scroll", onScroll, { passive: true });
  window.addEventListener("resize", function () {
    if (window.innerWidth > 900) closeMenu();
    onScroll();
  }, { passive: true });
  onFrame();

  // 当前区块高亮
  if ("IntersectionObserver" in window && sections.length) {
    var navObserver = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          var id = entry.target.id;
          navLinks.forEach(function (link) {
            link.classList.toggle(
              "is-active",
              link.getAttribute("data-nav") === id
            );
          });
        });
      },
      { rootMargin: "-45% 0px -50% 0px", threshold: 0 }
    );
    sections.forEach(function (section) {
      navObserver.observe(section);
    });
  }

  // 页脚“回到顶部”不写入历史之外的行为，交给原生锚点即可。

  /* ── 滚动显现 ──────────────────────────────────────────────────────── */

  var revealEls = Array.prototype.slice.call(
    doc.querySelectorAll("[data-reveal], [data-media-reveal]")
  );

  // 同一组内错开，最多 6 级
  revealEls.forEach(function (el) {
    var index = 0;
    var sibling = el.previousElementSibling;
    while (sibling) {
      if (sibling.hasAttribute && sibling.hasAttribute("data-reveal")) index++;
      sibling = sibling.previousElementSibling;
    }
    el.style.setProperty("--d", Math.min(index, 6) * 65 + "ms");
  });

  if (reduceMotion || !("IntersectionObserver" in window)) {
    revealEls.forEach(function (el) {
      el.classList.add("is-in");
    });
  } else {
    var revealObserver = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-in");
          revealObserver.unobserve(entry.target);
        });
      },
      { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
    );
    revealEls.forEach(function (el) {
      revealObserver.observe(el);
    });
  }

  /* ── 产品叙事：滚动切换视图 ────────────────────────────────────────── */

  (function setupShowcase() {
    var steps = Array.prototype.slice.call(
      doc.querySelectorAll(".showcase-step")
    );
    var views = Array.prototype.slice.call(
      doc.querySelectorAll(".stage-view")
    );
    var stageEl = doc.querySelector(".showcase-stage");
    var label = doc.querySelector("[data-stage-label]");

    if (!steps.length || !views.length) return;

    function activate(index) {
      steps.forEach(function (step, i) {
        step.classList.toggle("is-active", i === index);
      });
      views.forEach(function (view, i) {
        view.classList.toggle("is-active", i === index);
      });
      if (label) {
        label.textContent =
          "PRODUCT VIEW 0" + (index + 1) + " / 0" + steps.length;
      }
      if (stageEl) stageEl.setAttribute("data-stage", String(index));
    }

    if (!("IntersectionObserver" in window)) {
      activate(0);
      return;
    }

    var stepObserver = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          var index = Number(entry.target.getAttribute("data-step"));
          if (!isNaN(index)) activate(index);
        });
      },
      window.innerWidth <= 1024
        ? { rootMargin: "-58% 0px -22% 0px", threshold: 0 }
        : { rootMargin: "-42% 0px -42% 0px", threshold: 0 }
    );

    steps.forEach(function (step) {
      stepObserver.observe(step);
    });
    activate(0);
  })();

  /* ── 页内开屏演示：进入视口自动播一次 ─────────────────────────────── */

  (function setupStageAutoplay() {
    if (!stage || !stageFrame) return;
    if (/[?&]preview\b/.test(window.location.search)) return;
    var played = false;

    function playOnce() {
      if (played) return;
      played = true;
      playStage();
    }

    if (!("IntersectionObserver" in window)) {
      playOnce();
      return;
    }

    var stageObserver = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          playOnce();
          stageObserver.disconnect();
        });
      },
      { threshold: 0.3 }
    );
    stageObserver.observe(stage);
  })();

  /* ── 跑马灯：复制一份内容以实现无缝循环 ────────────────────────────── */

  Array.prototype.forEach.call(
    doc.querySelectorAll("[data-ticker]"),
    function (track) {
      var items = track.innerHTML;
      var count = track.children.length;
      track.insertAdjacentHTML("beforeend", items);
      for (var i = count; i < track.children.length; i++) {
        track.children[i].setAttribute("aria-hidden", "true");
      }
    }
  );

  /* ── 播放页布局切换 ───────────────────────────────────────────────── */

  (function setupLayoutTabs() {
    var preview = doc.querySelector("[data-layout-preview]");
    var tabs = Array.prototype.slice.call(
      doc.querySelectorAll("[data-layout]")
    );
    if (!preview || !tabs.length) return;

    tabs.forEach(function (tab) {
      tab.addEventListener("click", function () {
        tabs.forEach(function (other) {
          var active = other === tab;
          other.classList.toggle("is-active", active);
          other.setAttribute("aria-selected", String(active));
        });
        var src = tab.getAttribute("data-src");
        if (src) preview.src = src;
      });
    });
  })();

  /* ── 界面画廊 / 大图预览 ───────────────────────────────────────────── */

  (function setupGallery() {
    var gallery = doc.querySelector("[data-gallery]");
    if (!gallery) return;

    var prev = doc.querySelector("[data-gallery-prev]");
    var next = doc.querySelector("[data-gallery-next]");
    var cards = gallery.querySelectorAll(".gallery-card");
    var firstCard = cards.length ? cards[0] : null;

    function step() {
      if (!firstCard) return 480;
      var gap =
        parseFloat(window.getComputedStyle(gallery).columnGap || "14") || 14;
      return firstCard.getBoundingClientRect().width + gap;
    }

    function updateNav() {
      if (!prev || !next) return;
      prev.disabled = gallery.scrollLeft < 4;
      next.disabled =
        gallery.scrollLeft + gallery.clientWidth >= gallery.scrollWidth - 4;
    }

    // 计数 / 进度完全由原生滚动位置与真实卡片宽度推导
    function updateMeta() {
      var max = gallery.scrollWidth - gallery.clientWidth;
      var p = max > 0 ? Math.min(Math.max(gallery.scrollLeft / max, 0), 1) : 0;

      if (galleryProgress) {
        galleryProgress.style.transform = "scaleX(" + p.toFixed(4) + ")";
      }
      if (!galleryCount || !cards.length) return;

      var active = max > 0 ? Math.round(gallery.scrollLeft / step()) + 1 : 1;
      if (gallery.scrollLeft >= max - 2) active = cards.length;
      active = Math.min(Math.max(active, 1), cards.length);
      galleryCount.textContent =
        "0" + active + " / 0" + cards.length;
    }

    function onGalleryScroll() {
      updateNav();
      updateMeta();
    }

    if (prev) {
      prev.addEventListener("click", function () {
        gallery.scrollBy({ left: -step(), behavior: "smooth" });
      });
    }
    if (next) {
      next.addEventListener("click", function () {
        gallery.scrollBy({ left: step(), behavior: "smooth" });
      });
    }

    gallery.addEventListener("scroll", onGalleryScroll, { passive: true });
    window.addEventListener("resize", onGalleryScroll, { passive: true });
    gallery.addEventListener("keydown", function (event) {
      if (event.key === "ArrowRight") {
        event.preventDefault();
        gallery.scrollBy({ left: step(), behavior: "smooth" });
      } else if (event.key === "ArrowLeft") {
        event.preventDefault();
        gallery.scrollBy({ left: -step(), behavior: "smooth" });
      }
    });
    onGalleryScroll();
  })();

  (function setupLightbox() {
    var box = doc.getElementById("lightbox");
    var image = doc.getElementById("lightbox-image");
    var caption = doc.getElementById("lightbox-caption");
    var closeBtn = doc.querySelector("[data-lightbox-close]");
    if (!box || !image || !caption) return;

    var lastFocus = null;

    function open(trigger) {
      lastFocus = trigger || null;
      image.src = trigger.getAttribute("data-full") || "";
      var label = trigger.getAttribute("data-caption") || "";
      var alt = trigger.querySelector("img");
      image.alt = alt ? alt.getAttribute("alt") || label : label;
      caption.textContent = label;
      box.classList.add("is-open");
      box.setAttribute("aria-hidden", "false");
      body.classList.add("lightbox-open");
      if (closeBtn) closeBtn.focus();
    }

    function close() {
      box.classList.remove("is-open");
      box.setAttribute("aria-hidden", "true");
      body.classList.remove("lightbox-open");
      image.removeAttribute("src");
      if (lastFocus && typeof lastFocus.focus === "function") lastFocus.focus();
    }

    Array.prototype.forEach.call(
      doc.querySelectorAll("[data-lightbox]"),
      function (trigger) {
        trigger.addEventListener("click", function () {
          open(trigger);
        });
      }
    );

    if (closeBtn) closeBtn.addEventListener("click", close);
    box.addEventListener("click", function (event) {
      if (event.target === box) close();
    });
    doc.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && box.classList.contains("is-open")) {
        close();
      }
    });
  })();

  /* ── 初始化状态 ───────────────────────────────────────────────────── */

  setEngine(engine, false);

  var params = new URLSearchParams(window.location.search);
  var preview = params.has("preview");

  var engineParam = params.get("engine");
  if (engineParam === "eraudio" || engineParam === "stable") {
    setEngine(engineParam, false);
  }

  if (params.has("static")) {
    var screen = full.querySelector(".splash-screen");
    full.classList.add("is-active");
    full.setAttribute("aria-hidden", "false");
    screen.classList.toggle("engine-on", engine === "eraudio");
    screen.classList.add("is-static");
  } else if (!params.has("nosplash") && !preview) {
    showSplash();
  } else {
    full.classList.remove("is-active");
    full.setAttribute("aria-hidden", "true");
    markReady();
  }

  // 静态预览：跳过入场动画与滚动显现，直接呈现终态（截图 / 观感检查用）
  if (preview) {
    doc.documentElement.classList.add("preview");
    revealEls.forEach(function (el) {
      el.classList.add("is-in");
    });
    if (stageFrame) {
      var previewStage = stageFrame.querySelector(".splash-screen");
      previewStage.classList.toggle("engine-on", engine === "eraudio");
      previewStage.classList.add("is-static");
    }
  }

  // 演示区直接呈现动画终态（截图 / 观感检查用）
  if (params.get("stage") === "end" && stageFrame) {
    var stageScreen = stageFrame.querySelector(".splash-screen");
    play(stageScreen, { engine: engine, speed: 0.001 });
  }

  // 供首屏兜底脚本判断主脚本是否已正常跑完
  window.archoeraSiteReady = true;
})();
