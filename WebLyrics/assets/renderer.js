(() => {
  // horizontal-scroll.ts
  var measuring = document.createElement("canvas").getContext("2d");
  var reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  var residualVelocity = 7 * Math.exp(-6);
  function landingDistance(u) {
    return ((2 - (6 * u + 2) * Math.exp(-6 * u)) / 6 - residualVelocity * u) / (1 - residualVelocity);
  }
  var fullLanding = landingDistance(1);
  function scrollProgress(t, durationMS) {
    if (t <= 0 || t >= 1 || reducedMotion.matches) return t;
    const edge = Math.min(0.22, 480 / Math.max(1, durationMS));
    const distance = 1 - 1.5 * edge + edge * fullLanding;
    if (t < edge) {
      const u = t / edge;
      return edge * u * u * u * (1 - 0.5 * u) / distance;
    }
    if (t <= 1 - edge) return (t - 0.5 * edge) / distance;
    return (1 - 1.5 * edge + edge * landingDistance((t - 1 + edge) / edge)) / distance;
  }
  var HorizontalScroll = class {
    constructor(main, row, nextStart, clock) {
      this.main = main;
      this.row = row;
      this.nextStart = nextStart;
      this.clock = clock;
      const last = row.words[row.words.length - 1];
      this.duration = Math.max(1, Math.min(last.endTime, row.endTime, nextStart) - row.startTime);
      this.hold = Math.min(300, this.duration * 0.1);
      this.mainContent = main.firstChild;
      this.translation = main.nextElementSibling;
      this.translatedText = this.translation.firstElementChild;
      if (!this.translatedText && this.translation.firstChild) {
        this.translatedText = document.createElement("span");
        this.translatedText.append(this.translation.firstChild);
        this.translation.append(this.translatedText);
      }
      measuring.font = getComputedStyle(main).font || "600 14px sans-serif";
      for (const w of row.words) this.widths.push(this.widths[this.widths.length - 1] + measuring.measureText(w.word).width);
      this.observer = new ResizeObserver(() => this.layout());
      this.observer.observe(main.parentElement);
      this.observer.observe(main);
      if (this.translatedText) this.observer.observe(this.translatedText);
      this.layout();
    }
    main;
    row;
    nextStart;
    clock;
    lanes = [];
    translation;
    observer;
    duration;
    hold;
    mainContent;
    translatedText;
    widths = [0];
    hasContent() {
      return this.main.isConnected && this.main.firstChild === this.mainContent && this.translation.firstChild === this.translatedText;
    }
    wordProgress(ms) {
      const words = this.row.words;
      let lo = 0, hi = words.length - 1;
      while (lo < hi) {
        const mid = lo + hi >>> 1;
        if (ms < words[mid].endTime) hi = mid;
        else lo = mid + 1;
      }
      const w = words[lo];
      const f = Math.min(1, Math.max(0, (ms - w.startTime) / Math.max(1, w.endTime - w.startTime)));
      return (this.widths[lo] + f * (this.widths[lo + 1] - this.widths[lo])) / Math.max(1, this.widths[this.widths.length - 1]);
    }
    lineProgress(t) {
      return Math.min(1, Math.max(0, (t - this.hold) / Math.max(1, this.duration - 2 * this.hold)));
    }
    dimensions = "";
    layout(force = false) {
      const main = this.main, line = main.parentElement;
      const lineStyle = getComputedStyle(line), style = getComputedStyle(main);
      const room = line.clientWidth - parseFloat(lineStyle.paddingLeft) - parseFloat(lineStyle.paddingRight);
      const width = main.offsetWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
      const subOverflow = this.translatedText ? this.translatedText.offsetWidth - this.translation.clientWidth : 0;
      const dimensions = [width, room, subOverflow].join(",");
      if (dimensions === this.dimensions && !force) return;
      this.dimensions = dimensions;
      this.clear();
      const excess = width - room;
      if (excess > 0) {
        const limit = excess + 8;
        const radius = Math.min(82, this.duration * 0.06);
        this.add(main, line, excess, (t) => {
          const ms2 = t + this.row.startTime;
          const head = (this.wordProgress(ms2 - radius) + 2 * this.wordProgress(ms2 - radius / 2) + 3 * this.wordProgress(ms2) + 2 * this.wordProgress(ms2 + radius / 2) + this.wordProgress(ms2 + radius)) / 9;
          const finish = Math.max(0, (this.lineProgress(t) - 0.8) / 0.2);
          const target = Math.min(1, Math.max(0, (width * head - room * 0.6) / limit, finish));
          return limit * scrollProgress(target, this.duration);
        });
      }
      if (subOverflow > 0 && this.translatedText) {
        this.add(this.translatedText, this.translation, subOverflow, (t) => (subOverflow + 8) * scrollProgress(this.lineProgress(t), this.duration - 2 * this.hold));
      }
      const { ms, running } = this.clock();
      this.sync(ms, running);
    }
    add(text, clip, excess, offset) {
      const steps = Math.max(2, Math.min(300, Math.ceil(this.duration / 25)));
      const times = /* @__PURE__ */ new Set([0, this.hold, this.duration - this.hold, this.duration]);
      for (let i = 1; i < steps; i++) times.add(this.duration * i / steps);
      if (text === this.main && this.duration / steps > 25) {
        for (const w of this.row.words) {
          for (const time of [w.startTime, w.endTime]) {
            const t = time - this.row.startTime;
            if (t > 0 && t < this.duration) times.add(t);
          }
        }
      }
      let previousT = 0, previousX = 0, leadingAt = Infinity, trailingUntil = Infinity;
      const frames = Array.from(times).sort((a, b) => a - b).map((t) => {
        const x = t === 0 ? 0 : offset(t);
        const crossing = (threshold) => previousT + (t - previousT) * (threshold - previousX) / (x - previousX);
        if (leadingAt === Infinity && x > 1) leadingAt = crossing(1);
        if (trailingUntil === Infinity && x >= excess - 1)
          trailingUntil = previousX >= excess - 1 ? previousT : crossing(excess - 1);
        previousT = t;
        previousX = x;
        return { offset: t / this.duration, transform: `translate3d(${-x}px,0,0)` };
      });
      const animation = text.animate(frames, { duration: this.duration, fill: "both" });
      this.lanes.push({ text, clip, animation, leadingAt, trailingUntil, edges: -1 });
    }
    sync(ms, running) {
      const t = Math.min(this.duration, Math.max(0, ms - this.row.startTime));
      for (const { animation } of this.lanes) {
        if (running && t < this.duration) {
          const timeline = document.timeline.currentTime;
          if (animation.playState !== "running" || Math.abs(Number(animation.currentTime) - t) > 20) {
            animation.play();
            if (typeof timeline === "number") animation.startTime = timeline - t;
            else animation.currentTime = t;
          }
        } else {
          animation.pause();
          animation.currentTime = t;
        }
      }
      this.updateEdges(ms);
    }
    updateEdges(ms) {
      const t = ms - this.row.startTime;
      for (const lane of this.lanes) {
        const mask = (t > lane.leadingAt ? 1 : 0) | (t < lane.trailingUntil ? 2 : 0);
        if (mask === lane.edges) continue;
        lane.edges = mask;
        lane.clip.classList.toggle("fade-leading", !!(mask & 1));
        lane.clip.classList.toggle("fade-trailing", !!(mask & 2));
      }
    }
    clear() {
      for (const lane of this.lanes) lane.animation.cancel();
      this.lanes = [];
      this.main.style.transform = "";
      if (this.translatedText) this.translatedText.style.transform = "";
      this.main.parentElement?.classList.remove("fade-leading", "fade-trailing");
      this.translation.classList.remove("fade-leading", "fade-trailing");
    }
    dispose() {
      this.observer.disconnect();
      for (const { animation, text } of this.lanes) {
        if (text.isConnected) text.style.transform = getComputedStyle(text).transform;
        animation.cancel();
      }
      this.lanes = [];
    }
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/styles/lyric-player.module.css
  var lyric_player_default = {
    lyricLineWrapper: "lyric_player_lyricLineWrapper",
    lyricLine: "lyric_player_lyricLine",
    gradientMask: "lyric_player_gradientMask",
    lyricDuetLine: "lyric_player_lyricDuetLine",
    lyricMainLine: "lyric_player_lyricMainLine",
    romanWord: "lyric_player_romanWord",
    rubyWord: "lyric_player_rubyWord",
    wordWithRuby: "lyric_player_wordWithRuby",
    wordBody: "lyric_player_wordBody",
    rubyBaseWord: "lyric_player_rubyBaseWord",
    emphasizeWrapper: "lyric_player_emphasizeWrapper",
    emphasize: "lyric_player_emphasize",
    lyricBgLine: "lyric_player_lyricBgLine",
    active: "lyric_player_active",
    lyricSubLine: "lyric_player_lyricSubLine",
    bottomLine: "lyric_player_bottomLine",
    bgWrapper: "lyric_player_bgWrapper",
    bgWrapperTop: "lyric_player_bgWrapperTop",
    bgWrapperActive: "lyric_player_bgWrapperActive",
    bgWrapperHidden: "lyric_player_bgWrapperHidden",
    interludeDots: "lyric_player_interludeDots",
    enabled: "lyric_player_enabled",
    duet: "lyric_player_duet",
    disableSpring: "lyric_player_disableSpring",
    tmpDisableTransition: "lyric_player_tmpDisableTransition",
    playing: "lyric_player_playing",
    hasDuetLine: "lyric_player_hasDuetLine",
    isDuetWrapper: "lyric_player_isDuetWrapper"
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/utils/clamp.ts
  function clamp(x, min, max) {
    return Math.min(Math.max(x, min), max);
  }
  function clamp01(x) {
    return clamp(x, 0, 1);
  }
  function clampPositive(x) {
    return Math.max(0, x);
  }

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/utils/optimize-lyric.ts
  var DEFAULT_OPTIMIZE_OPTIONS = {
    normalizeSpaces: true,
    resetLineTimestamps: true,
    convertExcessiveBackgroundLines: true,
    syncMainAndBackgroundLines: true,
    cleanUnintentionalOverlaps: true,
    tryAdvanceStartTime: true
  };
  function normalizeSpaces(lines) {
    for (const line of lines) {
      for (const word of line.words) {
        word.word = word.word.replace(/\s+/g, " ");
      }
    }
  }
  function resetLineTimestamps(lines) {
    for (const line of lines) {
      if (line.words.length === 1 && line.words[0].startTime === 0 && line.words[0].endTime === 0 && (line.startTime !== 0 || line.endTime !== 0)) {
        line.words[0].startTime = line.startTime;
        line.words[0].endTime = line.endTime;
      } else if (line.words.length > 0) {
        const firstWord = line.words[0];
        const lastWord = line.words[line.words.length - 1];
        line.startTime = firstWord.startTime;
        line.endTime = lastWord.endTime;
      }
    }
  }
  function convertExcessiveBackgroundLines(lines) {
    let consecutiveBgCount = 0;
    for (const line of lines) {
      if (line.isBG) {
        consecutiveBgCount++;
        if (consecutiveBgCount > 1) {
          line.isBG = false;
        }
      } else {
        consecutiveBgCount = 0;
      }
    }
  }
  function syncMainAndBackgroundLines(lines) {
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i];
      if (line.isBG) continue;
      const nextLine = lines[i + 1];
      if (nextLine?.isBG) {
        const allWords = [...line.words, ...nextLine.words].filter(
          (w) => w.word.trim().length > 0
        );
        if (allWords.length > 0) {
          const minStart = Math.min(...allWords.map((w) => w.startTime));
          const maxEnd = Math.max(...allWords.map((w) => w.endTime));
          const finalStart = Math.min(
            minStart,
            line.startTime,
            nextLine.startTime
          );
          const finalEnd = Math.max(maxEnd, line.endTime, nextLine.endTime);
          line.startTime = finalStart;
          line.endTime = finalEnd;
          nextLine.startTime = finalStart;
          nextLine.endTime = finalEnd;
        }
      }
    }
  }
  function cleanUnintentionalOverlaps(lines) {
    for (let i = 0; i < lines.length - 1; i++) {
      const line = lines[i];
      if (line.isBG) continue;
      let nextMainIndex = i + 1;
      while (nextMainIndex < lines.length && lines[nextMainIndex].isBG) {
        nextMainIndex++;
      }
      if (nextMainIndex < lines.length) {
        const nextLine = lines[nextMainIndex];
        const overlap = line.endTime - nextLine.startTime;
        if (overlap > 0) {
          const nextDuration = nextLine.endTime - nextLine.startTime;
          const percentageThreshold = nextDuration * 0.1;
          const isIntentionalOverlap = overlap > 100 && overlap > percentageThreshold;
          if (!isIntentionalOverlap) {
            line.endTime = nextLine.startTime;
            const attachedBgLine = lines[i + 1];
            if (attachedBgLine?.isBG) {
              attachedBgLine.endTime = nextLine.startTime;
            }
          }
        }
      }
    }
  }
  function tryAdvanceStartTime(lines) {
    const defaultAdvanceAmount = 600;
    const fallbackAdvanceAmount = 400;
    const fallbackAdvanceRatio = 0.3;
    let prevLineStartTime = 0;
    let prevLineEndTime = 0;
    let prevMainGroupStartTime = 0;
    let prevMainGroupEndTime = 0;
    let hasPrevLine = false;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.isBG) continue;
      const originalStartTime = line.startTime;
      const originalEndTime = line.endTime;
      let targetAdvanceAmount = 0;
      let safeBoundary = 0;
      if (hasPrevLine) {
        const originallyHadGap = originalStartTime >= prevLineEndTime;
        if (originallyHadGap) {
          targetAdvanceAmount = defaultAdvanceAmount;
          safeBoundary = prevMainGroupEndTime;
        } else {
          targetAdvanceAmount = fallbackAdvanceAmount;
          const prevDuration = prevLineEndTime - prevLineStartTime;
          safeBoundary = prevLineStartTime + prevDuration * fallbackAdvanceRatio;
        }
      } else {
        targetAdvanceAmount = defaultAdvanceAmount;
        safeBoundary = 0;
      }
      const targetTime = line.startTime - targetAdvanceAmount;
      const newStartTime = Math.max(safeBoundary, targetTime);
      if (newStartTime < line.startTime) {
        line.startTime = newStartTime;
      }
      const nextLine = lines[i + 1];
      if (nextLine?.isBG) {
        nextLine.startTime = line.startTime;
      }
      if (hasPrevLine) {
        const overlapsPrevGroup = originalStartTime < prevMainGroupEndTime && originalEndTime > prevMainGroupStartTime;
        if (overlapsPrevGroup) {
          prevMainGroupStartTime = Math.min(
            prevMainGroupStartTime,
            originalStartTime
          );
          prevMainGroupEndTime = Math.max(prevMainGroupEndTime, originalEndTime);
        } else {
          prevMainGroupStartTime = originalStartTime;
          prevMainGroupEndTime = originalEndTime;
        }
      } else {
        prevMainGroupStartTime = originalStartTime;
        prevMainGroupEndTime = originalEndTime;
      }
      prevLineStartTime = originalStartTime;
      prevLineEndTime = originalEndTime;
      hasPrevLine = true;
    }
  }
  function areOptimizeOptionsEqual(a = {}, b = {}) {
    const keysA = Object.keys(a);
    const keysB = Object.keys(b);
    if (keysA.length !== keysB.length) return false;
    for (const key of keysA) {
      if (a[key] !== b[key]) return false;
    }
    return true;
  }
  function optimizeLyricLines(lines, options) {
    const config = { ...DEFAULT_OPTIMIZE_OPTIONS, ...options };
    if (config.normalizeSpaces) {
      normalizeSpaces(lines);
    }
    if (config.resetLineTimestamps) {
      resetLineTimestamps(lines);
    }
    if (config.convertExcessiveBackgroundLines) {
      convertExcessiveBackgroundLines(lines);
    }
    if (config.syncMainAndBackgroundLines) {
      syncMainAndBackgroundLines(lines);
    }
    if (config.cleanUnintentionalOverlaps) {
      cleanUnintentionalOverlaps(lines);
    }
    if (config.tryAdvanceStartTime) {
      tryAdvanceStartTime(lines);
    }
  }

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/dom/interlude-dots.ts
  function easeInOutBack(x) {
    const c1 = 1.70158;
    const c2 = c1 * 1.525;
    return x < 0.5 ? (2 * x) ** 2 * ((c2 + 1) * 2 * x - c2) / 2 : ((2 * x - 2) ** 2 * ((c2 + 1) * (x * 2 - 2) + c2) + 2) / 2;
  }
  function easeOutExpo(x) {
    return x === 1 ? 1 : 1 - 2 ** (-10 * x);
  }
  var InterludeDots = class {
    element = document.createElement("div");
    dot0 = document.createElement("span");
    dot1 = document.createElement("span");
    dot2 = document.createElement("span");
    left = 0;
    top = 0;
    playing = true;
    lastStyle = "";
    currentInterlude;
    currentTime = 0;
    targetBreatheDuration = 1500;
    constructor() {
      this.element.className = lyric_player_default.interludeDots;
      this.element.appendChild(this.dot0);
      this.element.appendChild(this.dot1);
      this.element.appendChild(this.dot2);
    }
    getElement() {
      return this.element;
    }
    setTransform(left = this.left, top = this.top) {
      this.left = left;
      this.top = top;
      this.update();
    }
    /**
     * 设置间奏点动画区间并重新锚定时间
     * @param interlude 间奏起止时间
     * @param currentTime 当前播放时间
     * @param forceReset 是否强制重置动画起点，如 Seek、重新布局或切换间奏时
     */
    setInterlude(interlude, currentTime, forceReset = false) {
      if (!interlude) {
        this.currentInterlude = void 0;
        this.element.classList.remove(lyric_player_default.enabled);
        return;
      }
      const endTime = interlude[1];
      const now = currentTime ?? interlude[0];
      const isNewInterlude = !this.currentInterlude || this.currentInterlude[1] !== endTime;
      const shouldReset = forceReset || isNewInterlude;
      if (shouldReset) {
        this.currentInterlude = [now, endTime];
        this.currentTime = now;
      }
      this.element.classList.add(lyric_player_default.enabled);
    }
    pause() {
      this.playing = false;
      this.element.classList.remove(lyric_player_default.playing);
    }
    resume() {
      this.playing = true;
      this.element.classList.add(lyric_player_default.playing);
    }
    update(delta = 0) {
      if (!this.playing) return;
      this.currentTime += delta;
      let curStyle = "";
      curStyle += `transform:translate(${this.left.toFixed(
        2
      )}px, ${this.top.toFixed(2)}px)`;
      if (this.currentInterlude) {
        const interludeDuration = this.currentInterlude[1] - this.currentInterlude[0];
        const currentDuration = this.currentTime - this.currentInterlude[0];
        if (currentDuration <= interludeDuration) {
          const breatheDuration = interludeDuration / Math.ceil(interludeDuration / this.targetBreatheDuration);
          let scale = 1;
          let globalOpacity = 1;
          scale *= Math.sin(1.5 * Math.PI - currentDuration / breatheDuration * 2) / 20 + 1;
          if (currentDuration < 2e3) {
            scale *= easeOutExpo(currentDuration / 2e3);
          }
          if (currentDuration < 500) {
            globalOpacity = 0;
          } else if (currentDuration < 1e3) {
            globalOpacity *= (currentDuration - 500) / 500;
          }
          if (interludeDuration - currentDuration < 750) {
            scale *= 1 - easeInOutBack(
              (750 - (interludeDuration - currentDuration)) / 750 / 2
            );
          }
          if (interludeDuration - currentDuration < 375) {
            globalOpacity *= clamp01((interludeDuration - currentDuration) / 375);
          }
          const dotsDuration = clampPositive(interludeDuration - 750);
          scale = clampPositive(scale) * 0.7;
          curStyle += ` scale(${scale})`;
          const dot0Opacity = clamp(
            0.25,
            currentDuration * 3 / dotsDuration * 0.75,
            1
          );
          const dot1Opacity = clamp(
            0.25,
            (currentDuration - dotsDuration / 3) * 3 / dotsDuration * 0.75,
            1
          );
          const dot2Opacity = clamp(
            0.25,
            (currentDuration - dotsDuration / 3 * 2) * 3 / dotsDuration * 0.75,
            1
          );
          this.dot0.style.opacity = `${clamp01(globalOpacity * dot0Opacity)}`;
          this.dot1.style.opacity = `${clamp01(globalOpacity * dot1Opacity)}`;
          this.dot2.style.opacity = `${clamp01(globalOpacity * dot2Opacity)}`;
        } else {
          curStyle += " scale(0)";
          this.dot0.style.opacity = "0";
          this.dot1.style.opacity = "0";
          this.dot2.style.opacity = "0";
        }
        curStyle += ";";
        if (this.lastStyle !== curStyle) {
          this.element.setAttribute("style", curStyle);
          this.lastStyle = curStyle;
        }
      }
    }
    dispose() {
      this.element.remove();
    }
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/utils/schedule.ts
  var measureTasks = [];
  var mutateTasks = [];
  var scheduled = false;
  function onFlush() {
    let tmp = mutateTasks.shift();
    while (tmp) {
      try {
        tmp.resolve(tmp.task());
      } catch (error) {
        tmp.reject(error);
      }
      tmp = mutateTasks.shift();
    }
    tmp = measureTasks.shift();
    while (tmp) {
      try {
        tmp.resolve(tmp.task());
      } catch (error) {
        tmp.reject(error);
      }
      tmp = measureTasks.shift();
    }
    scheduled = false;
  }
  function scheduleFlush() {
    if (!scheduled) {
      scheduled = true;
      requestAnimationFrame(onFlush);
    }
  }
  function measure(callback) {
    const task = {
      task: callback,
      resolve: () => {
      },
      reject: () => {
      }
    };
    const promise = new Promise((resolve, reject) => {
      task.resolve = resolve;
      task.reject = reject;
    });
    measureTasks.push(task);
    scheduleFlush();
    return promise;
  }

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/utils/derivative.ts
  function derivative(f) {
    const h = 1e-3;
    return (x) => (f(x + h) - f(x - h)) / (2 * h);
  }
  function getVelocity(f) {
    return derivative(f);
  }

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/utils/spring.ts
  var Spring = class {
    currentPosition = 0;
    targetPosition = 0;
    currentTime = 0;
    params = {};
    currentSolver;
    getV;
    getV2;
    queueParams;
    queuePosition;
    constructor(currentPosition = 0) {
      this.targetPosition = currentPosition;
      this.currentPosition = this.targetPosition;
      this.currentSolver = () => this.targetPosition;
      this.getV = () => 0;
      this.getV2 = () => 0;
    }
    resetSolver() {
      const curV = this.getV(this.currentTime);
      this.currentTime = 0;
      this.currentSolver = solveSpring(
        this.currentPosition,
        curV,
        this.targetPosition,
        0,
        this.params
      );
      this.getV = getVelocity(this.currentSolver);
      this.getV2 = getVelocity(this.getV);
    }
    arrived() {
      return Math.abs(this.targetPosition - this.currentPosition) < 0.01 && Math.abs(this.getV(this.currentTime)) < 0.01 && Math.abs(this.getV2(this.currentTime)) < 0.01 && this.queueParams === void 0 && this.queuePosition === void 0;
    }
    setPosition(targetPosition) {
      this.targetPosition = targetPosition;
      this.currentPosition = targetPosition;
      this.currentSolver = () => this.targetPosition;
      this.getV = () => 0;
      this.getV2 = () => 0;
    }
    update(delta = 0) {
      this.currentTime += delta;
      this.currentPosition = this.currentSolver(this.currentTime);
      if (this.queueParams) {
        this.queueParams.time -= delta;
        if (this.queueParams.time <= 0) {
          this.updateParams({
            ...this.queueParams
          });
        }
      }
      if (this.queuePosition) {
        this.queuePosition.time -= delta;
        if (this.queuePosition.time <= 0) {
          this.setTargetPosition(this.queuePosition.position);
        }
      }
      if (this.arrived()) {
        this.setPosition(this.targetPosition);
      }
    }
    updateParams(params, delay = 0) {
      if (delay > 0) {
        this.queueParams = {
          ...this.queuePosition ?? {},
          ...params,
          time: delay
        };
      } else {
        this.queuePosition = void 0;
        this.params = {
          ...this.params,
          ...params
        };
        this.resetSolver();
      }
    }
    setTargetPosition(targetPosition, delay = 0) {
      if (delay <= 0 && Math.abs(this.targetPosition - targetPosition) < 1e-3) {
        this.queuePosition = void 0;
        return;
      }
      if (delay > 0) {
        this.queuePosition = {
          ...this.queuePosition ?? {},
          position: targetPosition,
          time: delay
        };
      } else {
        this.queuePosition = void 0;
        this.targetPosition = targetPosition;
        this.resetSolver();
      }
    }
    getCurrentPosition() {
      return this.currentPosition;
    }
  };
  function solveSpring(from, velocity, to, delay = 0, params) {
    const soft = params?.soft ?? false;
    const stiffness = params?.stiffness ?? 100;
    const damping = params?.damping ?? 10;
    const mass = params?.mass ?? 1;
    const delta = to - from;
    if (soft || 1 <= damping / (2 * Math.sqrt(stiffness * mass))) {
      const angular_frequency = -Math.sqrt(stiffness / mass);
      const leftover2 = -angular_frequency * delta - velocity;
      return (t) => {
        t -= delay;
        if (t < 0) return from;
        return to - (delta + t * leftover2) * Math.E ** (t * angular_frequency);
      };
    }
    const damping_frequency = Math.sqrt(4 * mass * stiffness - damping ** 2);
    const leftover = (damping * delta - 2 * mass * velocity) / damping_frequency;
    const dfm = 0.5 * damping_frequency / mass;
    const dm = -(0.5 * damping) / mass;
    return (t) => {
      t -= delay;
      if (t < 0) return from;
      return to - (Math.cos(t * dfm) * delta + Math.sin(t * dfm) * leftover) * Math.E ** (t * dm);
    };
  }

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/base/bottom-line.ts
  var BottomLineEl = class {
    constructor(lyricPlayer) {
      this.lyricPlayer = lyricPlayer;
      this.element.setAttribute(
        "class",
        `${lyric_player_default.lyricLine} ${lyric_player_default.bottomLine}`
      );
      this.element.dataset.bottomLine = "true";
      this.rebuildStyle();
    }
    lyricPlayer;
    element = document.createElement("div");
    left = 0;
    top = 0;
    // 由 LyricPlayer 来设置
    lineSize = [0, 0];
    lineTransforms = {
      posX: new Spring(0),
      posY: new Spring(0)
    };
    isFocused = false;
    blur = 0;
    lastTransformStyle = "";
    lastFilterStyle = "";
    async measureSize() {
      const size = await measure(() => [
        this.element.clientWidth,
        this.element.clientHeight
      ]);
      return size;
    }
    show() {
      this.rebuildStyle();
    }
    hide() {
      this.rebuildStyle();
    }
    setFocused(focused) {
      if (this.isFocused !== focused) {
        this.isFocused = focused;
        if (focused) {
          this.element.dataset.focused = "true";
        } else {
          delete this.element.dataset.focused;
        }
      }
    }
    rebuildStyle() {
      const style = this.element.style;
      const posX = this.lineTransforms.posX.getCurrentPosition().toFixed(2);
      const posY = this.lineTransforms.posY.getCurrentPosition().toFixed(2);
      const transformStr = `translate(${posX}px, ${posY}px)`;
      if (this.lastTransformStyle !== transformStr) {
        this.lastTransformStyle = transformStr;
        style.transform = transformStr;
      }
      const blurVal = Math.min(5, this.blur);
      const filterStr = blurVal > 0.01 ? `blur(${blurVal.toFixed(2)}px)` : "none";
      if (this.lastFilterStyle !== filterStr) {
        this.lastFilterStyle = filterStr;
        style.filter = filterStr;
      }
    }
    getElement() {
      return this.element;
    }
    setTransform(left = this.left, top = this.top, blur = 0, immediate = false, delay = 0) {
      this.left = left;
      this.top = top;
      if (immediate || !this.lyricPlayer.getEnableSpring()) {
        this.blur = Math.min(32, blur);
        if (immediate) this.element.classList.add(lyric_player_default.tmpDisableTransition);
        this.lineTransforms.posX.setPosition(left);
        this.lineTransforms.posY.setPosition(top);
        if (!this.lyricPlayer.getEnableSpring()) this.show();
        else this.rebuildStyle();
        if (immediate)
          requestAnimationFrame(() => {
            this.element.classList.remove(lyric_player_default.tmpDisableTransition);
          });
      } else {
        this.blur = Math.min(5, blur);
        this.lineTransforms.posX.setTargetPosition(left, delay);
        this.lineTransforms.posY.setTargetPosition(top, delay);
      }
    }
    update(delta = 0) {
      if (!this.lyricPlayer.getEnableSpring()) return;
      this.lineTransforms.posX.update(delta);
      this.lineTransforms.posY.update(delta);
      if (this.isInSight) {
        this.show();
      } else {
        this.hide();
      }
    }
    get isInSight() {
      const l = this.lineTransforms.posX.getCurrentPosition();
      const t = this.lineTransforms.posY.getCurrentPosition();
      const r = l + this.lineSize[0];
      const b = t + this.lineSize[1];
      const pr = this.lyricPlayer.size[0];
      const pb = this.lyricPlayer.size[1];
      return !(l > pr || t > pb || r < 0 || b < 0);
    }
    dispose() {
      this.element.remove();
    }
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/base/consts.ts
  var MaskObsceneWordsMode = {
    /** 禁用任何不雅用语掩码 */
    Disabled: "",
    /** 完全掩码所有不雅用语 */
    FullMask: "full-mask",
    /** 保留首尾字符，屏蔽中间字符 */
    PartialMask: "partial-mask"
  };
  var LyricLineRenderMode = {
    SOLID: 0,
    GRADIENT: 1
  };
  var LayoutAlignAnchor = {
    Top: "top",
    Center: "center",
    Bottom: "bottom"
  };
  var LayoutReason = {
    /** 正常播放时间推进 */
    PlaybackTick: "playback-tick",
    /** 容器或窗口尺寸调整 */
    Resize: "resize",
    /** 用户交互挂起开始（触摸/滚轮触发） */
    InteractionStart: "interaction-start",
    /** 连续高频滚动（手指触摸滑动或松手后的 RAF 惯性滑动） */
    ContinuousScroll: "continuous-scroll",
    /** 离散单步滚动（鼠标滚轮单次滚动） */
    DiscreteScroll: "discrete-scroll",
    /** 用户交互结束并恢复自动对齐 */
    InteractionEnd: "interaction-end",
    /** 跳转播放进度 */
    Seek: "seek",
    /** 重新构建歌词视图 */
    RebuildView: "rebuild-view",
    /** 视图结构或样式配置改变 */
    ConfigChange: "config-change"
  };
  var LayoutReasonStrategyMap = {
    [LayoutReason.PlaybackTick]: {
      disableStagger: false,
      resetInterlude: false,
      snapPosY: false
    },
    [LayoutReason.InteractionEnd]: {
      disableStagger: false,
      resetInterlude: false,
      snapPosY: false
    },
    [LayoutReason.ContinuousScroll]: {
      disableStagger: true,
      resetInterlude: true,
      snapPosY: true
    },
    [LayoutReason.DiscreteScroll]: {
      disableStagger: true,
      resetInterlude: true,
      snapPosY: false
    },
    [LayoutReason.InteractionStart]: {
      disableStagger: true,
      resetInterlude: true,
      snapPosY: false
    },
    [LayoutReason.Seek]: {
      disableStagger: true,
      resetInterlude: true,
      snapPosY: false
    },
    // RebuildView 时也不应该瞬移 Y 轴，因为载入歌词时有一个歌词行从底部远处飞入的动画，需要弹簧来动画
    [LayoutReason.RebuildView]: {
      disableStagger: true,
      resetInterlude: true,
      snapPosY: false
    },
    [LayoutReason.Resize]: {
      disableStagger: true,
      resetInterlude: false,
      snapPosY: false
    },
    [LayoutReason.ConfigChange]: {
      disableStagger: true,
      resetInterlude: false,
      snapPosY: false
    }
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/base/layout.ts
  var LayoutCalculator = class {
    //#region 内部状态
    /**
     * 前缀和缓存
     *
     * 长度为歌词行数 + 1
     *
     * prefixSums[i] 存储的是第 0 行到第 i-1 行的总高度，不包含间奏点
     */
    prefixSums = new Float64Array(0);
    heights = new Float64Array(0);
    /**
     * 使用 Uint8Array 作为掩码，1 表示该行经历了真实测量，0 表示该行在使用 fallback 高度
     */
    isMeasured = new Uint8Array(0);
    /**
     * 渲染指令对象池
     *
     * 长度永远只会增加不会减少，避免 GC
     */
    instructionPool = [];
    isPrefixSumDirty = true;
    resolvedMetrics = {
      isValid: false,
      focalTopY: 0,
      anchorOffset: 0,
      interludeTotalHeight: 0,
      activeInterludeAnchor: void 0
    };
    /**
     * 全局唯一复用的返回结果实例
     */
    layoutResult = {
      lineCount: 0,
      lineInstructions: this.instructionPool,
      bottomLineY: 0,
      isBottomLineInViewport: false,
      hasInterlude: false,
      interludeY: 0
    };
    /**
     * 缓存的歌词行数
     */
    lyricCount = 0;
    /**
     * 缓存的所有歌词总高度
     */
    totalLyricHeight = 0;
    //#endregion
    //#region 公共 API
    /**
     * 初始化排版空间结构与高度缓存
     *
     * 在加载新歌词时调用
     *
     * @param count 歌词总行数
     * @param defaultHeight 尚未渲染/测量的行的默认回退高度
     */
    initHeights(count, defaultHeight) {
      this.lyricCount = count;
      this.resetLayoutResult();
      if (this.prefixSums.length < count + 1) {
        this.prefixSums = new Float64Array(count + 1);
        this.heights = new Float64Array(count);
        this.isMeasured = new Uint8Array(count);
      } else {
        this.prefixSums.fill(0);
      }
      for (let i = 0; i < count; i++) {
        this.heights[i] = defaultHeight;
        this.isMeasured[i] = 0;
      }
      this.isPrefixSumDirty = true;
      const currentPoolSize = this.instructionPool.length;
      if (count > currentPoolSize) {
        for (let i = currentPoolSize; i < count; i++) {
          this.instructionPool.push({
            y: 0,
            height: 0,
            isInViewport: false
          });
        }
      }
    }
    /**
     * 获取指定索引歌词行的计算高度
     * @remarks 可能为测量值或估算值
     * @param index 歌词行索引
     */
    getLineHeight(index) {
      if (index < 0 || index >= this.lyricCount) return 0;
      this.ensurePrefixSums();
      return this.prefixSums[index + 1] - this.prefixSums[index];
    }
    /**
     * 设置单行歌词的真实测量高度
     * @param index 歌词行索引
     * @param height 真实测量的高度
     */
    setLineHeight(index, height) {
      if (index < 0 || index >= this.lyricCount) return;
      if (this.heights[index] !== height || this.isMeasured[index] === 0) {
        this.heights[index] = height;
        this.isMeasured[index] = 1;
        this.isPrefixSumDirty = true;
      }
    }
    /**
     * 批量更新所有未测量行的回退高度
     *
     * 仅在容器 Resize 等会导致回退基准（如 containerHeight / 5）发生变化时调用。
     * 已被真实测量的行不受影响。
     *
     * @param defaultHeight 新的默认回退高度
     */
    updateUnmeasuredHeights(defaultHeight) {
      let changed = false;
      for (let i = 0; i < this.lyricCount; i++) {
        if (this.isMeasured[i] === 0 && this.heights[i] !== defaultHeight) {
          this.heights[i] = defaultHeight;
          changed = true;
        }
      }
      if (changed) {
        this.isPrefixSumDirty = true;
      }
    }
    /**
     * 解析焦点度量并计算物理滚动边界
     *
     * 返回滚动安全闭区间 `{ min, max }` 以及此帧的生命周期会话句柄 {@link LayoutFrameSession}
     * 供后续使用 `ScrollInteractionEngine.updateBoundary` 钳制 `scrollOffset` 后传给 {@link commit}
     *
     * @param ctx 动态帧上下文，包含当前容器尺寸、焦点目标与底栏高度
     * @param config 布局静态配置，包含对齐锚点、相对位置与 Overscan 容差
     */
    beginFrame(ctx, config) {
      this.ensurePrefixSums();
      const metrics = this.resolveLayoutMetrics(ctx, config);
      const session = {
        ...metrics,
        containerHeight: ctx.containerHeight,
        alignPosition: config.alignPosition,
        overscanPx: config.overscanPx,
        bottomLineHeight: ctx.bottomLineHeight
      };
      if (!metrics.isValid) {
        return { bounds: { min: 0, max: 0 }, session };
      }
      const {
        focalTopY,
        anchorOffset,
        interludeTotalHeight,
        activeInterludeAnchor
      } = metrics;
      const minOffset = Math.min(0, -focalTopY);
      const basePosWithoutScroll = -focalTopY + ctx.containerHeight * config.alignPosition - anchorOffset;
      let totalContentHeight = this.totalLyricHeight;
      if (activeInterludeAnchor !== void 0) {
        totalContentHeight += interludeTotalHeight;
      }
      const rawMaxOffset = basePosWithoutScroll + totalContentHeight - ctx.containerHeight / 2;
      const maxOffset = Math.max(0, rawMaxOffset);
      return { bounds: { min: minOffset, max: maxOffset }, session };
    }
    /**
     * 基于已钳制的 `scrollOffset` 和第一阶段的 {@link LayoutFrameSession} 提交排版并生成指令
     *
     * @param session 由 {@link beginFrame} 生成的单帧排版会话
     * @param scrollOffset 经过边界钳制后的安全滚动偏移量
     *
     * @returns 复用的排版结果实例 {@link LayoutResult}
     */
    commit(session, scrollOffset) {
      this.ensurePrefixSums();
      if (!session.isValid) {
        return this.resetLayoutResult();
      }
      this.layoutResult.lineCount = this.lyricCount;
      const {
        focalTopY,
        anchorOffset,
        interludeTotalHeight,
        activeInterludeAnchor,
        containerHeight,
        alignPosition,
        overscanPx,
        bottomLineHeight
      } = session;
      const viewportStartY = containerHeight * alignPosition - anchorOffset - scrollOffset - focalTopY;
      const motionBuffer = containerHeight * 0.4;
      const viewportTopBound = -overscanPx - motionBuffer;
      const viewportBottomBound = containerHeight + overscanPx + motionBuffer;
      for (let i = 0; i < this.lyricCount; i++) {
        const instruction = this.instructionPool[i];
        let lineY = viewportStartY + this.prefixSums[i];
        const lineH = this.prefixSums[i + 1] - this.prefixSums[i];
        if (activeInterludeAnchor !== void 0 && i > activeInterludeAnchor) {
          lineY += interludeTotalHeight;
        }
        instruction.y = lineY;
        instruction.height = lineH;
        instruction.isInViewport = lineY <= viewportBottomBound && lineY + lineH >= viewportTopBound;
      }
      if (activeInterludeAnchor !== void 0) {
        this.layoutResult.hasInterlude = true;
        this.layoutResult.interludeY = viewportStartY + this.prefixSums[activeInterludeAnchor + 1];
      } else {
        this.layoutResult.hasInterlude = false;
        this.layoutResult.interludeY = 0;
      }
      let bottomY = viewportStartY + this.totalLyricHeight;
      if (activeInterludeAnchor !== void 0) {
        bottomY += interludeTotalHeight;
      }
      this.layoutResult.bottomLineY = bottomY;
      this.layoutResult.isBottomLineInViewport = bottomY <= viewportBottomBound && bottomY + bottomLineHeight >= viewportTopBound;
      return this.layoutResult;
    }
    //#endregion
    //#region 工具方法
    /**
     * 解析当前排版帧所对应的间奏点挂载锚点行索引
     *
     * @param interlude 当前时间线处于激活状态的间奏点信息
     * @param focalTarget 当前帧对齐的物理焦点
     */
    static resolveInterludeAnchorIndex(interlude, focalTarget) {
      if (interlude) {
        return interlude.anchorLineIndex;
      }
      if (focalTarget.type === "interlude") {
        return focalTarget.anchorIndex;
      }
      return void 0;
    }
    /**
     * 如果高度发生过改变，则重新计算前缀和
     */
    ensurePrefixSums() {
      if (!this.isPrefixSumDirty) return;
      let sum = 0;
      this.prefixSums[0] = 0;
      for (let i = 0; i < this.lyricCount; i++) {
        sum += this.heights[i];
        this.prefixSums[i + 1] = sum;
      }
      this.totalLyricHeight = sum;
      this.isPrefixSumDirty = false;
    }
    /**
     * 公共的焦点度量与范围校验逻辑
     */
    resolveLayoutMetrics(ctx, config) {
      const interludeTotalHeight = ctx.interlude?.totalHeight ?? 0;
      const activeInterludeAnchor = ctx.interlude?.anchorIndex;
      this.resolvedMetrics.interludeTotalHeight = interludeTotalHeight;
      this.resolvedMetrics.activeInterludeAnchor = activeInterludeAnchor;
      if (this.lyricCount === 0 || ctx.target.type === "line" && (ctx.target.index < 0 || ctx.target.index >= this.lyricCount) || ctx.target.type === "interlude" && (ctx.target.anchorIndex < -1 || ctx.target.anchorIndex >= this.lyricCount - 1)) {
        this.resolvedMetrics.isValid = false;
        this.resolvedMetrics.focalTopY = 0;
        this.resolvedMetrics.anchorOffset = 0;
        return this.resolvedMetrics;
      }
      this.updateFocalMetrics(
        ctx.target,
        interludeTotalHeight,
        activeInterludeAnchor,
        ctx.bottomLineHeight,
        config
      );
      this.resolvedMetrics.isValid = true;
      return this.resolvedMetrics;
    }
    /**
     * 测量对齐目标的几何信息
     */
    updateFocalMetrics(target, interludeTotalHeight, activeInterludeAnchor, bottomLineHeight, config) {
      let focalTopY = 0;
      let targetHeight = 0;
      if (target.type === "line") {
        focalTopY = this.prefixSums[target.index];
        if (activeInterludeAnchor !== void 0 && target.index > activeInterludeAnchor) {
          focalTopY += interludeTotalHeight;
        }
        targetHeight = this.prefixSums[target.index + 1] - this.prefixSums[target.index];
      } else if (target.type === "interlude") {
        focalTopY = this.prefixSums[target.anchorIndex + 1];
        targetHeight = interludeTotalHeight;
      } else if (target.type === "bottom") {
        focalTopY = this.totalLyricHeight;
        if (activeInterludeAnchor !== void 0) {
          focalTopY += interludeTotalHeight;
        }
        targetHeight = bottomLineHeight;
      }
      this.resolvedMetrics.focalTopY = focalTopY;
      this.resolvedMetrics.anchorOffset = this.calculateAnchorOffset(
        config.alignAnchor,
        targetHeight
      );
    }
    /**
     * 根据锚点与目标高度计算内部相对偏移
     */
    calculateAnchorOffset(alignAnchor, targetHeight) {
      if (targetHeight <= 0) return 0;
      switch (alignAnchor) {
        case LayoutAlignAnchor.Top:
          return 0;
        case LayoutAlignAnchor.Center:
          return targetHeight / 2;
        case LayoutAlignAnchor.Bottom:
          return targetHeight;
      }
      const exhaustiveCheck = alignAnchor;
      return exhaustiveCheck;
    }
    /**
     * 重置排版结果为安全干净的状态（全部不可见/无底栏）
     */
    resetLayoutResult() {
      this.layoutResult.lineCount = 0;
      this.layoutResult.hasInterlude = false;
      this.layoutResult.interludeY = 0;
      this.layoutResult.bottomLineY = 0;
      this.layoutResult.isBottomLineInViewport = false;
      for (let i = 0; i < this.instructionPool.length; i++) {
        this.instructionPool[i].isInViewport = false;
        this.instructionPool[i].y = 0;
        this.instructionPool[i].height = 0;
      }
      return this.layoutResult;
    }
    //#endregion
  };

  // ../../../../../../../Code/applemusic-like-lyrics/node_modules/.pnpm/@ungap+structured-clone@1.3.3/node_modules/@ungap/structured-clone/esm/types.js
  var VOID = -1;
  var PRIMITIVE = 0;
  var ARRAY = 1;
  var OBJECT = 2;
  var DATE = 3;
  var REGEXP = 4;
  var MAP = 5;
  var SET = 6;
  var ERROR = 7;
  var BIGINT = 8;

  // ../../../../../../../Code/applemusic-like-lyrics/node_modules/.pnpm/@ungap+structured-clone@1.3.3/node_modules/@ungap/structured-clone/esm/deserialize.js
  var env = typeof self === "object" ? self : globalThis;
  var guard = (name, init) => {
    switch (name) {
      case "Function":
      case "SharedWorker":
      case "Worker":
      case "eval":
      case "setInterval":
      case "setTimeout":
        throw new TypeError("unable to deserialize " + name);
    }
    return new env[name](init);
  };
  var deserializer = ($, _) => {
    const as = (out, index) => {
      $.set(index, out);
      return out;
    };
    const unpair = (index) => {
      if ($.has(index))
        return $.get(index);
      const [type, value] = _[index];
      switch (type) {
        case PRIMITIVE:
        case VOID:
          return as(value, index);
        case ARRAY: {
          const arr = as([], index);
          for (const index2 of value)
            arr.push(unpair(index2));
          return arr;
        }
        case OBJECT: {
          const object = as({}, index);
          for (const [key, index2] of value)
            object[unpair(key)] = unpair(index2);
          return object;
        }
        case DATE:
          return as(new Date(value), index);
        case REGEXP: {
          const { source, flags } = value;
          return as(new RegExp(source, flags), index);
        }
        case MAP: {
          const map = as(/* @__PURE__ */ new Map(), index);
          for (const [key, index2] of value)
            map.set(unpair(key), unpair(index2));
          return map;
        }
        case SET: {
          const set = as(/* @__PURE__ */ new Set(), index);
          for (const index2 of value)
            set.add(unpair(index2));
          return set;
        }
        case ERROR: {
          const { name, message } = value;
          return as(
            typeof env[name] === "function" ? guard(name, message) : new Error(message),
            index
          );
        }
        case BIGINT:
          return as(BigInt(value), index);
        case "BigInt":
          return as(Object(BigInt(value)), index);
        case "ArrayBuffer":
          return as(new Uint8Array(value).buffer, value);
        case "DataView": {
          const { buffer } = new Uint8Array(value);
          return as(new DataView(buffer), value);
        }
      }
      return as(guard(type, value), index);
    };
    return unpair;
  };
  var deserialize = (serialized) => deserializer(/* @__PURE__ */ new Map(), serialized)(0);

  // ../../../../../../../Code/applemusic-like-lyrics/node_modules/.pnpm/@ungap+structured-clone@1.3.3/node_modules/@ungap/structured-clone/esm/serialize.js
  var EMPTY = "";
  var { toString } = {};
  var { keys } = Object;
  var typeOf = (value) => {
    const type = typeof value;
    if (type !== "object" || !value)
      return [PRIMITIVE, type];
    const asString = toString.call(value).slice(8, -1);
    switch (asString) {
      case "Array":
        return [ARRAY, EMPTY];
      case "Object":
        return [OBJECT, EMPTY];
      case "Date":
        return [DATE, EMPTY];
      case "RegExp":
        return [REGEXP, EMPTY];
      case "Map":
        return [MAP, EMPTY];
      case "Set":
        return [SET, EMPTY];
      case "DataView":
        return [ARRAY, asString];
    }
    if (asString.includes("Array"))
      return [ARRAY, asString];
    if (value instanceof Error)
      return [ERROR, value.name || "Error"];
    return [OBJECT, asString];
  };
  var shouldSkip = ([TYPE, type]) => TYPE === PRIMITIVE && (type === "function" || type === "symbol");
  var serializer = (strict, json, $, _) => {
    const as = (out, value) => {
      const index = _.push(out) - 1;
      $.set(value, index);
      return index;
    };
    const pair = (value) => {
      if ($.has(value))
        return $.get(value);
      let [TYPE, type] = typeOf(value);
      switch (TYPE) {
        case PRIMITIVE: {
          let entry = value;
          switch (type) {
            case "bigint":
              TYPE = BIGINT;
              entry = value.toString();
              break;
            case "function":
            case "symbol":
              if (strict)
                throw new TypeError("unable to serialize " + type);
              entry = null;
              break;
            case "undefined":
              return as([VOID], value);
          }
          return as([TYPE, entry], value);
        }
        case ARRAY: {
          if (type) {
            let spread = value;
            if (type === "DataView") {
              spread = new Uint8Array(value.buffer);
            } else if (type === "ArrayBuffer") {
              spread = new Uint8Array(value);
            }
            return as([type, [...spread]], value);
          }
          const arr = [];
          const index = as([TYPE, arr], value);
          for (const entry of value)
            arr.push(pair(entry));
          return index;
        }
        case OBJECT: {
          if (type) {
            switch (type) {
              case "BigInt":
                return as([type, value.toString()], value);
              case "Boolean":
              case "Number":
              case "String":
                return as([type, value.valueOf()], value);
            }
          }
          if (json && "toJSON" in value)
            return pair(value.toJSON());
          const entries = [];
          const index = as([TYPE, entries], value);
          for (const key of keys(value)) {
            if (strict || !shouldSkip(typeOf(value[key])))
              entries.push([pair(key), pair(value[key])]);
          }
          return index;
        }
        case DATE:
          return as([TYPE, isNaN(value.getTime()) ? EMPTY : value.toISOString()], value);
        case REGEXP: {
          const { source, flags } = value;
          return as([TYPE, { source, flags }], value);
        }
        case MAP: {
          const entries = [];
          const index = as([TYPE, entries], value);
          for (const [key, entry] of value) {
            if (strict || !(shouldSkip(typeOf(key)) || shouldSkip(typeOf(entry))))
              entries.push([pair(key), pair(entry)]);
          }
          return index;
        }
        case SET: {
          const entries = [];
          const index = as([TYPE, entries], value);
          for (const entry of value) {
            if (strict || !shouldSkip(typeOf(entry)))
              entries.push(pair(entry));
          }
          return index;
        }
      }
      const { message } = value;
      return as([TYPE, { name: type, message }], value);
    };
    return pair;
  };
  var serialize = (value, { json, lossy } = {}) => {
    const _ = [];
    return serializer(!(json || lossy), !!json, /* @__PURE__ */ new Map(), _)(value), _;
  };

  // ../../../../../../../Code/applemusic-like-lyrics/node_modules/.pnpm/@ungap+structured-clone@1.3.3/node_modules/@ungap/structured-clone/esm/index.js
  var esm_default = typeof structuredClone === "function" ? (
    /* c8 ignore start */
    (any, options) => options && ("json" in options || "lossy" in options) ? deserialize(serialize(any, options)) : structuredClone(any)
  ) : (any, options) => deserialize(serialize(any, options));

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/base/lyric-data-manager.ts
  var LyricDataManager = class {
    /**
     * 原始的歌词行数组
     */
    rawLines = [];
    /**
     * 经过处理后的歌词行数组
     */
    processedLines = [];
    /**
     * 当前处理好的 processedLines 是否已经失效
     */
    isDirty = true;
    optimizeOpts = {};
    maskMode = MaskObsceneWordsMode.Disabled;
    maskChar = "*";
    isNonDynamic = false;
    hasDuetLine = false;
    setOriginalLines(lines) {
      this.rawLines = esm_default(lines);
      this.isDirty = true;
    }
    setConfig(config) {
      if (config.optimizeOptions) {
        this.optimizeOpts = { ...this.optimizeOpts, ...config.optimizeOptions };
      }
      this.maskMode = config.maskMode ?? this.maskMode;
      this.maskChar = config.maskChar?.charAt(0) ?? this.maskChar;
      this.isDirty = true;
    }
    /**
     * 获取用户设置的原始歌词行数组，未经过优化和掩码
     * @returns 原始歌词行数组
     */
    getRawLines() {
      return this.rawLines;
    }
    /**
     * 获取对原始歌词行数组处理过的的歌词行数组
     * @returns 经过处理的歌词行数组
     */
    getProcessedLines() {
      this.ensurePipeline();
      return this.processedLines;
    }
    /**
     * 歌词是否为非动态歌词，又称为逐行歌词
     */
    getIsNonDynamic() {
      this.ensurePipeline();
      return this.isNonDynamic;
    }
    /**
     * 歌词是否包含对唱歌词
     */
    getHasDuetLine() {
      this.ensurePipeline();
      return this.hasDuetLine;
    }
    getOptimizeOptions() {
      return this.optimizeOpts;
    }
    getMaskMode() {
      return this.maskMode;
    }
    getMaskChar() {
      return this.maskChar;
    }
    ensurePipeline() {
      if (!this.isDirty) return;
      this.processPipeline();
      this.isDirty = false;
    }
    processPipeline() {
      this.processedLines = esm_default(this.rawLines);
      optimizeLyricLines(this.processedLines, this.optimizeOpts);
      let checkNonDynamic = true;
      let checkDuet = false;
      for (const line of this.processedLines) {
        if (line.words.length > 1) checkNonDynamic = false;
        if (line.isDuet) checkDuet = true;
        for (const word of line.words) {
          this.applyMask(word);
        }
      }
      this.isNonDynamic = checkNonDynamic && this.processedLines.length > 0;
      this.hasDuetLine = checkDuet;
    }
    applyMask(word) {
      if (!word.obscene || this.maskMode === MaskObsceneWordsMode.Disabled) {
        return;
      }
      const text = word.word;
      const maskChar = this.maskChar;
      if (this.maskMode === MaskObsceneWordsMode.FullMask) {
        word.word = text.replace(/\S/g, maskChar);
      } else if (this.maskMode === MaskObsceneWordsMode.PartialMask) {
        const trimmed = text.trim();
        if (trimmed.length <= 2) {
          word.word = text.replace(/\S/g, maskChar);
        } else {
          const startPos = text.indexOf(trimmed);
          const endPos = startPos + trimmed.length - 1;
          word.word = text.slice(0, startPos + 1) + text.slice(startPos + 1, endPos).replace(/\S/g, maskChar) + text.slice(endPos);
        }
      }
    }
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/base/scroll.ts
  var ScrollInteractionEngine = class {
    constructor(container, hooks) {
      this.container = container;
      this.hooks = hooks;
      const signal = this.abortController.signal;
      this.container.addEventListener("touchstart", this.onTouchStart, {
        passive: false,
        signal
      });
      this.container.addEventListener("touchmove", this.onTouchMove, {
        passive: false,
        signal
      });
      this.container.addEventListener("touchend", this.onTouchEnd, {
        passive: false,
        signal
      });
      this.container.addEventListener("touchcancel", this.onTouchCancel, {
        passive: false,
        signal
      });
      this.container.addEventListener("wheel", this.onWheel, {
        passive: false,
        signal
      });
    }
    container;
    hooks;
    offset = 0;
    minOffset = 0;
    maxOffset = 0;
    touchState = {
      startY: 0,
      startX: 0,
      lastY: 0,
      startOffset: 0,
      speed: 0,
      startTime: 0,
      /**
       * 是否已经突破 10px 意图阈值
       */
      isIntentConfirmed: false
    };
    /**
     * 记录 Touch 开始时被打断的既有状态
     */
    interruptedState = {
      hadInertia: false,
      hadTimer: false,
      wasInteracting: false
    };
    inertiaRafId = 0;
    scrolledTimeoutId = 0;
    isInteracting = false;
    wheelEndTimeoutId = 0;
    abortController = new AbortController();
    //#region 生命周期控制
    startInteraction(type) {
      if (!this.isInteracting) {
        this.isInteracting = true;
        this.hooks.onInteractionStart(type);
      }
    }
    endInteractionAndStartTimer() {
      if (this.isInteracting) {
        this.isInteracting = false;
        this.hooks.onInteractionEnd();
      }
      this.clearTimers();
      this.scrolledTimeoutId = window.setTimeout(() => {
        this.scrolledTimeoutId = 0;
        this.hooks.onAutoAlignResume();
      }, 5e3);
    }
    //#endregion
    //#region 原生事件绑定
    onTouchStart = (evt) => {
      if (evt.touches.length > 1) {
        const touch2 = evt.touches[0];
        const state3 = this.touchState;
        state3.startY = touch2.screenY;
        state3.startX = touch2.screenX;
        state3.lastY = touch2.screenY;
        state3.startOffset = this.offset;
        state3.startTime = Date.now();
        state3.speed = 0;
        return;
      }
      this.interruptedState.hadInertia = this.inertiaRafId !== 0;
      this.interruptedState.hadTimer = this.scrolledTimeoutId !== 0 || this.wheelEndTimeoutId !== 0;
      this.interruptedState.wasInteracting = this.isInteracting;
      this.clearTimers();
      const touch = evt.touches[0];
      const state2 = this.touchState;
      state2.startY = touch.screenY;
      state2.startX = touch.screenX;
      state2.lastY = touch.screenY;
      state2.startOffset = this.offset;
      state2.startTime = Date.now();
      state2.speed = 0;
      state2.isIntentConfirmed = false;
    };
    onTouchMove = (evt) => {
      const touch = evt.touches[0];
      const state2 = this.touchState;
      const deltaY = touch.screenY - state2.startY;
      const deltaX = touch.screenX - state2.startX;
      if (!state2.isIntentConfirmed) {
        if (Math.abs(deltaY) > 10 || Math.abs(deltaX) > 10) {
          state2.isIntentConfirmed = true;
          this.startInteraction("touch");
        } else {
          return;
        }
      }
      if (evt.cancelable) {
        evt.preventDefault();
      }
      const currentY = touch.screenY;
      this.offset = this.clampOffset(
        state2.startOffset - (currentY - state2.startY)
      );
      const now = Date.now();
      const dt = now - state2.startTime;
      if (dt > 0) {
        state2.speed = (currentY - state2.lastY) / dt;
      }
      state2.lastY = currentY;
      state2.startTime = now;
      this.hooks.onScrollUpdate(true);
    };
    onTouchCancel = (_evt) => {
      const state2 = this.touchState;
      if (!state2.isIntentConfirmed) {
        const { hadInertia, hadTimer, wasInteracting } = this.interruptedState;
        if (hadInertia || hadTimer || wasInteracting) {
          this.endInteractionAndStartTimer();
        }
        return;
      }
      state2.speed = 0;
      state2.startY = 0;
      this.endInteractionAndStartTimer();
    };
    onTouchEnd = (evt) => {
      const state2 = this.touchState;
      if (evt.touches.length > 0) {
        const remainingTouch = evt.touches[0];
        state2.startY = remainingTouch.screenY;
        state2.startX = remainingTouch.screenX;
        state2.lastY = remainingTouch.screenY;
        state2.startOffset = this.offset;
        state2.startTime = Date.now();
        state2.speed = 0;
        return;
      }
      if (!state2.isIntentConfirmed) {
        const { hadInertia, hadTimer, wasInteracting } = this.interruptedState;
        if (hadInertia || hadTimer || wasInteracting) {
          this.endInteractionAndStartTimer();
        }
        return;
      }
      state2.isIntentConfirmed = false;
      if (evt.cancelable) {
        evt.preventDefault();
      }
      state2.startY = 0;
      if (this.inertiaRafId) {
        cancelAnimationFrame(this.inertiaRafId);
        this.inertiaRafId = 0;
      }
      if (Math.abs(state2.speed) < 0.1) {
        state2.speed = 0;
      }
      if (Math.abs(state2.speed) > 0.05) {
        let lastFrameTime = performance.now();
        const onScrollFrame = (time) => {
          const dt = time - lastFrameTime;
          lastFrameTime = time;
          if (dt <= 0 || dt > 100) {
            this.inertiaRafId = requestAnimationFrame(onScrollFrame);
            return;
          }
          if (Math.abs(state2.speed) > 0.05) {
            this.offset -= state2.speed * dt;
            this.offset = this.clampOffset(this.offset);
            state2.speed *= 0.95 ** (dt / 16);
            this.hooks.onScrollUpdate(true);
            this.inertiaRafId = requestAnimationFrame(onScrollFrame);
          } else {
            this.inertiaRafId = 0;
            this.endInteractionAndStartTimer();
          }
        };
        this.inertiaRafId = requestAnimationFrame(onScrollFrame);
      } else {
        this.endInteractionAndStartTimer();
      }
    };
    onWheel = (evt) => {
      this.clearTimers();
      this.startInteraction("wheel");
      if (evt.cancelable) {
        evt.preventDefault();
      }
      if (evt.deltaMode === WheelEvent.DOM_DELTA_PIXEL) {
        this.offset += evt.deltaY;
      } else {
        this.offset += evt.deltaY * 50;
      }
      this.offset = this.clampOffset(this.offset);
      this.hooks.onScrollUpdate(false);
      this.wheelEndTimeoutId = window.setTimeout(() => {
        this.wheelEndTimeoutId = 0;
        this.endInteractionAndStartTimer();
      }, 150);
    };
    //#endregion
    //#region 工具
    /**
     * 将给定的偏移量限制在当前的 [minOffset, maxOffset] 边界内
     */
    clampOffset(val) {
      const min = Math.min(this.minOffset, this.maxOffset);
      const max = Math.max(this.minOffset, this.maxOffset);
      return Math.min(Math.max(val, min), max);
    }
    //#endregion
    //#region 外部干预逻辑
    /**
     * 更新允许的滚动边界，并返回钳制后的实际 offset
     *
     * @description
     * 在歌词发生排版变化，如页面 `resize`、加载了新歌词、展开背景歌词、歌词行高度改变时，
     * 计算出当前视口内允许滚动的上限与下限，通过此方法传给滚动引擎以确保滚动不会越界
     */
    updateBoundary(min, max) {
      this.minOffset = Math.min(0, min);
      this.maxOffset = Math.max(0, max);
      this.offset = this.clampOffset(this.offset);
      return this.offset;
    }
    /**
     * 覆盖当前的滚动偏移量并终止正在进行的惯性动画或等待状态
     *
     * @description
     * 当需要清空全部用户手势带来的临时滚动状态时，例如，用户点击了某行歌词触发了
     * Seek、歌曲切歌、或者 5 秒倒计时到期恢复自动对齐时，调用此方法重置滚动引擎
     */
    resetScroll(targetOffset = 0) {
      this.clearTimers();
      this.isInteracting = false;
      this.touchState.isIntentConfirmed = false;
      this.touchState.speed = 0;
      this.touchState.startY = 0;
      this.touchState.lastY = 0;
      this.touchState.startTime = 0;
      this.offset = this.clampOffset(targetOffset);
    }
    //#endregion
    //#region 清理
    clearTimers() {
      if (this.inertiaRafId) {
        cancelAnimationFrame(this.inertiaRafId);
        this.inertiaRafId = 0;
      }
      if (this.scrolledTimeoutId) {
        clearTimeout(this.scrolledTimeoutId);
        this.scrolledTimeoutId = 0;
      }
      if (this.wheelEndTimeoutId) {
        window.clearTimeout(this.wheelEndTimeoutId);
        this.wheelEndTimeoutId = 0;
      }
    }
    dispose() {
      this.abortController.abort();
      this.clearTimers();
    }
    //#endregion
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/base/spring.ts
  var SLOW_STIFFNESS = 90;
  var SLOW_DAMPING = 15;
  var MIN_INTERVAL = 100;
  var MAX_INTERVAL = 800;
  var MIN_STIFFNESS = 170;
  var MAX_STIFFNESS = 220;
  var DAMPING_MULTIPLIER = 2.2;
  var INTERVAL_EXPONENT = 0.2;
  function getPosYSpringPolicy(isSeeking, isInterludeActive, intervalMs) {
    if (isSeeking || isInterludeActive || intervalMs == null) {
      return {
        stiffness: SLOW_STIFFNESS,
        damping: SLOW_DAMPING
      };
    }
    const clampedInterval = Math.min(
      Math.max(intervalMs, MIN_INTERVAL),
      MAX_INTERVAL
    );
    let ratio = 1 - (clampedInterval - MIN_INTERVAL) / (MAX_INTERVAL - MIN_INTERVAL);
    ratio = ratio ** INTERVAL_EXPONENT;
    const targetStiffness = MIN_STIFFNESS + ratio * (MAX_STIFFNESS - MIN_STIFFNESS);
    const targetDamping = Math.sqrt(targetStiffness) * DAMPING_MULTIPLIER;
    return {
      stiffness: targetStiffness,
      damping: targetDamping
    };
  }

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/base/timeline.ts
  var TimelineController = class {
    //#region 内部状态
    lyricBounds = [];
    /**
     * 外部显式传入的持续性 Seek 状态（例如正在拖拽进度条）
     */
    isManualSeeking = false;
    /**
     * 预先计算的间奏区域
     */
    precalculatedInterludes = [];
    /**
     * 保存上次检索到的正在播放歌词的位置，用于避免每次都从头遍历所有歌词，提高性能
     */
    playbackCursor = 0;
    interludeCursor = 0;
    isFocusOnInterludeState = false;
    playingGroupsSet = /* @__PURE__ */ new Set();
    highlightedGroupsSet = /* @__PURE__ */ new Set();
    addedPlayingIds = [];
    removedPlayingIds = [];
    addedHighlightedIds = [];
    removedHighlightedIds = [];
    expiredHighlightedIds = [];
    snapshot = {
      currentTime: 0,
      isSeeking: false,
      playingGroups: this.playingGroupsSet,
      highlightedGroups: this.highlightedGroupsSet,
      scrollToIndex: 0,
      latestHighlightedIndex: void 0,
      isTimelineEmpty: true,
      isEndOfSong: false,
      activeInterlude: void 0,
      isFocusOnInterlude: false
    };
    diff = {
      hasChanged: false,
      addedPlaying: this.addedPlayingIds,
      removedPlaying: this.removedPlayingIds,
      addedHighlighted: this.addedHighlightedIds,
      removedHighlighted: this.removedHighlightedIds,
      isInterludeChanged: false,
      isScrollToChanged: false,
      isTimeJumped: false
    };
    //#endregion
    //#region 外部 API
    /**
     * 提前设置好歌词的时间数据，内部会根据此数据来进行时间线推导，同时预计算间奏区间
     */
    setTimeBounds(bounds) {
      this.lyricBounds = bounds;
      this.precalculatedInterludes = this.calculateInterludes(bounds);
      this.reset();
    }
    /**
     * 获取当前播放时间线状态的只读快照
     *
     * 用于给 UI 执行排版和计算各种歌词行的效果
     *
     * @remarks 在获取快照后，必须在同一帧内消费完毕，切勿保留其引用，因为下一帧就会被原地覆写
     * @returns 时间线快照
     */
    getSnapshot() {
      return this.snapshot;
    }
    sync(time, forceSeek = false) {
      this.addedPlayingIds.length = 0;
      this.removedPlayingIds.length = 0;
      this.addedHighlightedIds.length = 0;
      this.removedHighlightedIds.length = 0;
      this.expiredHighlightedIds.length = 0;
      const prevInterlude = this.snapshot.activeInterlude;
      const prevFocusOnInterlude = this.snapshot.isFocusOnInterlude;
      const prevScrollToIndex = this.snapshot.scrollToIndex;
      const isTimeRegression = time < this.snapshot.currentTime;
      const isJump = forceSeek || isTimeRegression;
      this.snapshot.isSeeking = this.isManualSeeking || isJump;
      if (this.snapshot.isSeeking) {
        this.performSeek(time);
      } else {
        this.performPlayback(time);
      }
      this.updateInterludeState(time, isJump);
      const isInterludeChanged = prevInterlude !== this.snapshot.activeInterlude;
      const isFocusChanged = prevFocusOnInterlude !== this.snapshot.isFocusOnInterlude;
      const isScrollToChanged = prevScrollToIndex !== this.snapshot.scrollToIndex;
      const hasChanged = isJump || this.addedPlayingIds.length > 0 || this.removedPlayingIds.length > 0 || this.addedHighlightedIds.length > 0 || this.removedHighlightedIds.length > 0 || isInterludeChanged || isFocusChanged || isScrollToChanged;
      this.snapshot.currentTime = time;
      this.snapshot.isTimelineEmpty = this.highlightedGroupsSet.size === 0;
      if (this.highlightedGroupsSet.size > 0) {
        let maxIndex = -1;
        for (const id of this.highlightedGroupsSet) {
          if (id > maxIndex) maxIndex = id;
        }
        this.snapshot.latestHighlightedIndex = maxIndex;
      } else {
        this.snapshot.latestHighlightedIndex = void 0;
      }
      this.snapshot.isEndOfSong = false;
      if (this.highlightedGroupsSet.size === 0 && this.lyricBounds.length > 0) {
        const lastLine = this.lyricBounds[this.lyricBounds.length - 1];
        if (time >= lastLine.endTime) {
          this.snapshot.isEndOfSong = true;
        }
      }
      this.diff.hasChanged = hasChanged;
      this.diff.isInterludeChanged = isInterludeChanged;
      this.diff.isScrollToChanged = isScrollToChanged;
      this.diff.isTimeJumped = isJump;
      return this.diff;
    }
    setSeekingState(isSeeking) {
      this.isManualSeeking = isSeeking;
      this.snapshot.isSeeking = isSeeking;
    }
    //#endregion
    //#region 时间线推导
    /**
     * 处理正常播放时的时间线推导
     */
    performPlayback(time) {
      for (const lastPlayingId of this.playingGroupsSet) {
        const bound = this.lyricBounds[lastPlayingId];
        if (!bound || time < bound.startTime || bound.endTime <= time) {
          this.playingGroupsSet.delete(lastPlayingId);
          this.removedPlayingIds.push(lastPlayingId);
        }
      }
      let cursor = Math.max(0, this.playbackCursor);
      const len = this.lyricBounds.length;
      while (cursor < len) {
        const bound = this.lyricBounds[cursor];
        if (bound.startTime > time) {
          break;
        }
        if (bound.startTime <= time && bound.endTime > time && !this.playingGroupsSet.has(cursor)) {
          this.playingGroupsSet.add(cursor);
          this.addedPlayingIds.push(cursor);
        }
        cursor++;
      }
      if (this.playingGroupsSet.size > 0) {
        let minPlaying = Number.POSITIVE_INFINITY;
        for (const id of this.playingGroupsSet) {
          if (id < minPlaying) minPlaying = id;
        }
        this.playbackCursor = minPlaying;
      } else {
        this.playbackCursor = cursor;
      }
      this.expiredHighlightedIds.length = 0;
      for (const id of this.highlightedGroupsSet) {
        if (!this.playingGroupsSet.has(id)) {
          this.expiredHighlightedIds.push(id);
        }
      }
      const addedPlayingCount = this.addedPlayingIds.length;
      const expiredCount = this.expiredHighlightedIds.length;
      if (addedPlayingCount > 0) {
        for (let i = 0; i < addedPlayingCount; i++) {
          const id = this.addedPlayingIds[i];
          this.highlightedGroupsSet.add(id);
          this.addedHighlightedIds.push(id);
        }
      }
      const shouldTransitionToNext = addedPlayingCount > 0;
      const isCurrentGroupAllFinished = expiredCount > 0 && expiredCount === this.highlightedGroupsSet.size;
      const shouldFlushExpiredLines = shouldTransitionToNext || isCurrentGroupAllFinished;
      if (shouldFlushExpiredLines && expiredCount > 0) {
        for (let i = 0; i < expiredCount; i++) {
          const id = this.expiredHighlightedIds[i];
          this.highlightedGroupsSet.delete(id);
          this.removedHighlightedIds.push(id);
        }
      }
      if ((addedPlayingCount > 0 || shouldFlushExpiredLines) && this.highlightedGroupsSet.size > 0) {
        let minHighlighted = Number.POSITIVE_INFINITY;
        for (const id of this.highlightedGroupsSet) {
          if (id < minHighlighted) minHighlighted = id;
        }
        this.snapshot.scrollToIndex = minHighlighted;
      }
    }
    /**
     * 处理 Seek 时的时间线推导
     *
     * 将会丢弃所有高亮状态的行，直接根据当前时间重新计算播放状态的行
     */
    performSeek(time) {
      for (const id of this.playingGroupsSet) {
        this.removedPlayingIds.push(id);
      }
      for (const id of this.highlightedGroupsSet) {
        this.removedHighlightedIds.push(id);
      }
      this.playingGroupsSet.clear();
      this.highlightedGroupsSet.clear();
      let left = 0;
      let right = this.lyricBounds.length - 1;
      let firstGreaterOrEqual = this.lyricBounds.length;
      while (left <= right) {
        const mid = left + right >> 1;
        if (this.lyricBounds[mid].startTime >= time) {
          firstGreaterOrEqual = mid;
          right = mid - 1;
        } else {
          left = mid + 1;
        }
      }
      let minPlayingIndex = Number.POSITIVE_INFINITY;
      const startIndex = Math.min(
        firstGreaterOrEqual,
        this.lyricBounds.length - 1
      );
      for (let i = startIndex; i >= 0; i--) {
        const bound = this.lyricBounds[i];
        if (bound && bound.startTime <= time && bound.endTime > time) {
          this.playingGroupsSet.add(i);
          this.highlightedGroupsSet.add(i);
          this.addedPlayingIds.push(i);
          this.addedHighlightedIds.push(i);
          if (i < minPlayingIndex) minPlayingIndex = i;
        }
      }
      if (this.highlightedGroupsSet.size > 0) {
        this.snapshot.scrollToIndex = minPlayingIndex;
        this.playbackCursor = minPlayingIndex;
      } else {
        this.snapshot.scrollToIndex = firstGreaterOrEqual;
        this.playbackCursor = firstGreaterOrEqual;
      }
    }
    //#endregion
    //#region 间奏计算
    calculateInterludes(bounds) {
      const interludes = [];
      for (let i = -1; i < bounds.length - 1; i++) {
        const prevGroup = i === -1 ? null : bounds[i];
        const nextGroup = bounds[i + 1];
        const gapStart = prevGroup ? prevGroup.endTime : 0;
        const gapEnd = Math.max(gapStart, nextGroup.startTime);
        if (gapEnd - gapStart >= 4e3) {
          interludes.push({
            startTime: gapStart,
            endTime: gapEnd,
            anchorLineIndex: i
          });
        }
      }
      return interludes;
    }
    updateInterludeState(time, isSeek) {
      let activeInterlude;
      if (this.precalculatedInterludes.length > 0) {
        if (isSeek) {
          let cursor = this.precalculatedInterludes.length;
          let left = 0;
          let right = this.precalculatedInterludes.length - 1;
          while (left <= right) {
            const mid = left + right >> 1;
            const inter = this.precalculatedInterludes[mid];
            if (inter.endTime > time) {
              cursor = mid;
              right = mid - 1;
            } else {
              left = mid + 1;
            }
          }
          this.interludeCursor = cursor;
          if (cursor < this.precalculatedInterludes.length) {
            const inter = this.precalculatedInterludes[cursor];
            if (time >= inter.startTime && time < inter.endTime) {
              activeInterlude = inter;
            }
          }
        } else {
          while (this.interludeCursor < this.precalculatedInterludes.length) {
            const inter = this.precalculatedInterludes[this.interludeCursor];
            if (time >= inter.startTime && time < inter.endTime) {
              activeInterlude = inter;
              break;
            } else if (time >= inter.endTime) {
              this.interludeCursor++;
            } else {
              break;
            }
          }
        }
      }
      this.snapshot.activeInterlude = activeInterlude;
      if (activeInterlude && this.highlightedGroupsSet.size === 0) {
        this.isFocusOnInterludeState = true;
      } else if (this.highlightedGroupsSet.size > 0 || !activeInterlude) {
        this.isFocusOnInterludeState = false;
      }
      this.snapshot.isFocusOnInterlude = this.isFocusOnInterludeState;
    }
    //#endregion
    //#region 重置
    reset() {
      this.playbackCursor = 0;
      this.interludeCursor = 0;
      this.isFocusOnInterludeState = false;
      this.playingGroupsSet.clear();
      this.highlightedGroupsSet.clear();
      this.snapshot.currentTime = 0;
      this.snapshot.isSeeking = false;
      this.snapshot.scrollToIndex = 0;
      this.snapshot.latestHighlightedIndex = void 0;
      this.snapshot.isTimelineEmpty = true;
      this.snapshot.isEndOfSong = false;
      this.snapshot.activeInterlude = void 0;
      this.snapshot.isFocusOnInterlude = false;
    }
    //#endregion
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/base/index.ts
  function getEntrySize(entry) {
    if (entry.borderBoxSize && entry.borderBoxSize.length > 0) {
      const borderBox = entry.borderBoxSize[0];
      return [borderBox.inlineSize, borderBox.blockSize];
    }
    const el = entry.target;
    return [
      el.offsetWidth || entry.contentRect.width,
      el.offsetHeight || entry.contentRect.height
    ];
  }
  var LyricPlayerBase = class extends EventTarget {
    element = document.createElement("div");
    isPlaying = false;
    timelineController = new TimelineController();
    hasBottomContent = false;
    bottomLineObserver;
    /** @internal */
    lyricGroupElementMap = /* @__PURE__ */ new WeakMap();
    lyricLinesIndexes = /* @__PURE__ */ new WeakMap();
    disableSpring = false;
    dataManager = new LyricDataManager();
    get processedLines() {
      return this.dataManager.getProcessedLines();
    }
    get isNonDynamic() {
      return this.dataManager.getIsNonDynamic();
    }
    get hasDuetLine() {
      return this.dataManager.getHasDuetLine();
    }
    layoutState = {
      interludeDotsSize: [0, 0],
      alignTarget: { type: "line", index: 0 }
    };
    layoutConfig = {
      alignAnchor: LayoutAlignAnchor.Center,
      alignPosition: 0.35,
      overscanPx: 300
    };
    /** LayoutCalculator 所使用的排版上下文状态 */
    frameContext = {
      containerHeight: 0,
      scrollOffset: 0,
      target: { index: 0, type: "line" },
      bottomLineHeight: 0,
      interlude: void 0
    };
    interludeDots = new InterludeDots();
    bottomLine = new BottomLineEl(this);
    enableBlur = true;
    enableScale = true;
    hidePassedLines = false;
    scrollEngine;
    scrollState = {
      isAutoAlignSuspended: false,
      isTouchScrolled: false
    };
    layoutCalculator = new LayoutCalculator();
    currentLyricGroups = [];
    lyricGroupSize = /* @__PURE__ */ new WeakMap();
    size = [0, 0];
    isPageVisible = true;
    /** 默认/回退单行歌词估算高度基准 (containerHeight / 5) */
    get defaultLineHeight() {
      return this.size[1] / 5;
    }
    /**
     * 获取指定索引歌词行的高度
     * @remarks 可能为测量值或估算值
     */
    getLineHeight(index) {
      return this.layoutCalculator.getLineHeight(index);
    }
    /** 是否强制让背景人声行始终后置（即始终在主歌词下方显示，不前置背景人声） */
    alwaysPostpositionBackground = false;
    posXSpringParams = {
      mass: 1,
      damping: 10,
      stiffness: 100
    };
    posYSpringParams = {
      mass: 0.9,
      damping: 15,
      stiffness: 90
    };
    scaleSpringParams = {
      mass: 2,
      damping: 25,
      stiffness: 100
    };
    scaleForBGSpringParams = {
      mass: 1,
      damping: 20,
      stiffness: 50
    };
    lyricGroupIndexMap = /* @__PURE__ */ new WeakMap();
    onPageShow = () => {
      this.isPageVisible = true;
      this.setCurrentTime(
        this.timelineController.getSnapshot().currentTime,
        true
      );
    };
    onPageHide = () => {
      this.isPageVisible = false;
    };
    /** @internal */
    resizeObserver = new ResizeObserver(((entries) => {
      let shouldRelayout = false;
      let shouldRebuildPlayerStyle = false;
      let shouldUpdateFallback = false;
      for (const entry of entries) {
        if (entry.target === this.element) {
          const rect = entry.contentRect;
          this.size[0] = rect.width;
          this.size[1] = rect.height;
          shouldRebuildPlayerStyle = true;
          shouldUpdateFallback = true;
        } else if (entry.target === this.interludeDots.getElement()) {
          const size = getEntrySize(entry);
          this.layoutState.interludeDotsSize[0] = size[0];
          this.layoutState.interludeDotsSize[1] = size[1];
          shouldRelayout = true;
        } else if (entry.target === this.bottomLine.getElement()) {
          const newSize = getEntrySize(entry);
          const oldSize = this.bottomLine.lineSize;
          if (newSize[0] !== oldSize[0] || newSize[1] !== oldSize[1]) {
            this.bottomLine.lineSize = newSize;
            shouldRelayout = true;
          }
        } else {
          const groupObj = this.lyricGroupElementMap.get(entry.target);
          if (groupObj) {
            const newSize = getEntrySize(entry);
            const isGroupElement = entry.target === groupObj.getElement();
            if (isGroupElement) {
              const oldSize = this.lyricGroupSize.get(
                groupObj
              ) ?? [0, 0];
              if (newSize[0] !== oldSize[0] || newSize[1] !== oldSize[1]) {
                this.lyricGroupSize.set(groupObj, newSize);
                groupObj.onLineSizeChange(newSize);
                const index = this.lyricGroupIndexMap.get(groupObj) ?? -1;
                if (index !== -1) {
                  this.layoutCalculator.setLineHeight(index, newSize[1]);
                }
                shouldRelayout = true;
              }
            } else {
              groupObj.onBgSizeChange?.(newSize);
            }
          }
        }
      }
      if (shouldUpdateFallback) {
        this.layoutCalculator.updateUnmeasuredHeights(this.defaultLineHeight);
        shouldRelayout = true;
      }
      if (shouldRelayout) {
        this.calcLayout(LayoutReason.Resize);
      }
      if (shouldRebuildPlayerStyle) {
        this.onResize();
      }
    }));
    wordFadeWidth = 0.5;
    constructor(element) {
      super();
      if (element) this.element = element;
      this.element.classList.add("amll-lyric-player");
      this.resizeObserver.observe(this.element);
      this.resizeObserver.observe(this.interludeDots.getElement());
      this.resizeObserver.observe(this.bottomLine.getElement());
      this.element.appendChild(this.interludeDots.getElement());
      this.element.appendChild(this.bottomLine.getElement());
      this.interludeDots.setTransform(0, 200);
      this.bottomLineObserver = new MutationObserver(() => {
        const bottomEl = this.bottomLine.getElement();
        const newHasBottomContent = bottomEl.innerHTML.trim().length > 0;
        if (this.hasBottomContent !== newHasBottomContent) {
          this.hasBottomContent = newHasBottomContent;
          this.calcLayout(LayoutReason.ConfigChange);
        }
      });
      this.bottomLineObserver.observe(this.bottomLine.getElement(), {
        childList: true,
        characterData: true,
        subtree: true
      });
      window.addEventListener("pageshow", this.onPageShow);
      window.addEventListener("pagehide", this.onPageHide);
      this.scrollEngine = new ScrollInteractionEngine(this.element, {
        onScrollUpdate: (isContinuous) => {
          this.calcLayout(
            isContinuous ? LayoutReason.ContinuousScroll : LayoutReason.DiscreteScroll
          );
        },
        onInteractionStart: (type) => {
          this.scrollState.isAutoAlignSuspended = true;
          this.scrollState.isTouchScrolled = type === "touch";
          this.calcLayout(LayoutReason.InteractionStart);
        },
        onInteractionEnd: () => {
        },
        onAutoAlignResume: () => {
          this.scrollState.isAutoAlignSuspended = false;
          this.scrollState.isTouchScrolled = false;
          this.scrollEngine.resetScroll(0);
          this.calcLayout(LayoutReason.InteractionEnd);
        }
      });
    }
    /**
     * 设置文字动画的渐变宽度，单位以歌词行的主文字字体大小的倍数为单位，默认为 0.5，即一个全角字符的一半宽度
     *
     * 如果要模拟 Apple Music for Android 的效果，可以设置为 1
     *
     * 如果要模拟 Apple Music for iPad 的效果，可以设置为 0.5
     *
     * 如果想要近乎禁用渐变效果，可以设置成非常接近 0 的小数（例如 `0.0001` ），但是**不可以为 0**
     *
     * @param value 需要设置的渐变宽度，单位以歌词行的主文字字体大小的倍数为单位，默认为 0.5
     */
    setWordFadeWidth(value = 0.5) {
      this.wordFadeWidth = Math.max(1e-4, value);
    }
    /**
     * 是否启用歌词行缩放效果，默认启用
     *
     * 如果启用，非选中的歌词行会轻微缩小以凸显当前播放歌词行效果
     *
     * 此效果对性能影响微乎其微，推荐启用
     * @param enable 是否启用歌词行缩放效果
     */
    setEnableScale(enable = true) {
      this.enableScale = enable;
      this.calcLayout(LayoutReason.ConfigChange);
    }
    /**
     * 获取当前是否启用了歌词行缩放效果
     * @returns 是否启用歌词行缩放效果
     */
    getEnableScale() {
      return this.enableScale;
    }
    /**
     * 获取当前文字动画的渐变宽度，单位以歌词行的主文字字体大小的倍数为单位
     * @returns 当前文字动画的渐变宽度，单位以歌词行的主文字字体大小的倍数为单位
     */
    getWordFadeWidth() {
      return this.wordFadeWidth;
    }
    setIsSeeking(isSeeking) {
      this.timelineController.setSeekingState(isSeeking);
      this.updateSpringParams(
        !!this.timelineController.getSnapshot().activeInterlude
      );
    }
    /**
     * 设置是否隐藏已经播放过的歌词行，默认不隐藏
     * @param hide 是否隐藏已经播放过的歌词行，默认不隐藏
     */
    setHidePassedLines(hide) {
      this.hidePassedLines = hide;
      this.calcLayout(LayoutReason.ConfigChange);
    }
    /**
     * 设置是否启用歌词行的模糊效果
     * @param enable 是否启用
     */
    setEnableBlur(enable) {
      if (this.enableBlur === enable) return;
      this.enableBlur = enable;
      this.calcLayout(LayoutReason.ConfigChange);
    }
    /**
     * 批量更新歌词处理配置，包括优化和掩码设置
     *
     * @remarks
     * 此方法不会自动重建歌词行和刷新视图，
     * 适用于在渲染前预设配置、批量初始化，或需要手动控制 DOM 刷新时机的场景
     * @param config 需要更新的配置集合
     * @see {@link LyricDataConfig}
     */
    setLyricProcessConfig(config) {
      this.dataManager.setConfig(config);
    }
    /**
     * 批量更新歌词处理配置，包括优化和掩码设置
     *
     * 可以调用此方法以避免多次单独设置处理配置导致的多次刷新开销
     * @remarks 在设置完成后会自动重建歌词行和刷新视图
     * @param config 需要更新的配置集合
     * @see {@link LyricDataConfig}
     */
    updateLyricProcessConfig(config) {
      const currentOptimize = this.dataManager.getOptimizeOptions();
      const currentMaskMode = this.dataManager.getMaskMode();
      const currentMaskChar = this.dataManager.getMaskChar();
      const newOptimize = config.optimizeOptions !== void 0 ? config.optimizeOptions : currentOptimize;
      const newMaskMode = config.maskMode !== void 0 ? config.maskMode : currentMaskMode;
      const newMaskChar = config.maskChar !== void 0 ? config.maskChar : currentMaskChar;
      if (newMaskMode === currentMaskMode && newMaskChar === currentMaskChar && areOptimizeOptionsEqual(newOptimize, currentOptimize)) {
        return;
      }
      this.dataManager.setConfig({
        optimizeOptions: newOptimize,
        maskMode: newMaskMode,
        maskChar: newMaskChar
      });
      if (this.dataManager.getRawLines().length > 0) {
        this.rebuildLyricView(this.getCurrentTime());
        this.calcLayout(LayoutReason.ConfigChange);
      }
    }
    /**
     * 设置歌词中不雅用语的掩码模式
     * @remarks 在设置完成后会自动重建歌词行和刷新视图
     * @param mode 掩码模式
     * @see {@link MaskObsceneWordsMode}
     */
    setMaskObsceneWords(mode) {
      this.updateLyricProcessConfig({ maskMode: mode });
    }
    /**
     * 设置不雅用语掩码使用的字符，默认为 `*`
     * @remarks 在设置完成后会自动重建歌词行和刷新视图
     * @param char 单个字符，用于替换不雅用语中的字符
     */
    setMaskObsceneWordChar(char) {
      const c = char.charAt(0) || "*";
      this.updateLyricProcessConfig({ maskChar: c });
    }
    /**
     * 设置歌词的优化配置项，这些配置项默认全部开启
     * @remarks 在设置完成后会自动重建歌词行和刷新视图
     * @param options 优化配置选项
     * @see {@link OptimizeLyricOptions}
     */
    setOptimizeOptions(options) {
      const currentOpts = this.dataManager.getOptimizeOptions();
      this.updateLyricProcessConfig({
        optimizeOptions: { ...currentOpts, ...options }
      });
    }
    rebuildLyricLines() {
      for (const group of this.currentLyricGroups) {
        group.rebuildAllLines();
      }
    }
    /**
     * 设置目标歌词行的对齐方式，默认为 `center`
     *
     * - 设置成 `top` 的话将会向目标歌词行的顶部对齐
     * - 设置成 `bottom` 的话将会向目标歌词行的底部对齐
     * - 设置成 `center` 的话将会向目标歌词行的垂直中心对齐
     * @param alignAnchor 歌词行对齐方式，详情见函数说明
     */
    setAlignAnchor(alignAnchor) {
      this.layoutConfig.alignAnchor = alignAnchor;
    }
    /**
     * 设置默认的歌词行对齐位置，相对于整个歌词播放组件的大小位置，默认为 `0.5`
     * @param alignPosition 一个 `[0.0-1.0]` 之间的任意数字，代表组件高度由上到下的比例位置
     */
    setAlignPosition(alignPosition) {
      this.layoutConfig.alignPosition = alignPosition;
    }
    /**
     * 设置 overscan（视图上下额外缓冲渲染区）距离，单位：像素。
     * @param px 像素值，默认 300
     */
    setOverscanPx(px) {
      this.layoutConfig.overscanPx = clampPositive(px | 0);
    }
    /** 获取当前 overscan 像素距离 */
    getOverscanPx() {
      return this.layoutConfig.overscanPx;
    }
    /**
     * 设置是否使用物理弹簧算法实现歌词动画效果，默认启用
     *
     * 如果启用，则会通过弹簧算法实时处理歌词位置，但是需要性能足够强劲的电脑方可流畅运行
     *
     * 如果不启用，则会回退到基于 `transition` 的过渡效果，对低性能的机器比较友好，但是效果会比较单一
     */
    setEnableSpring(enable = true) {
      this.disableSpring = !enable;
      if (enable) {
        this.element.classList.remove(lyric_player_default.disableSpring);
      } else {
        this.element.classList.add(lyric_player_default.disableSpring);
      }
      this.calcLayout(LayoutReason.ConfigChange);
    }
    /**
     * 获取当前是否启用了物理弹簧
     * @returns 是否启用物理弹簧
     */
    getEnableSpring() {
      return !this.disableSpring;
    }
    /**
     * 设置当前播放歌词，要注意传入后这个数组内的信息不得修改，否则会发生错误
     * @param lines 歌词数组
     * @param initialTime 初始时间，默认为 0
     */
    setLyricLines(lines, initialTime = 0) {
      if (false) {
        console.log("\u8BBE\u7F6E\u6B4C\u8BCD\u884C", lines, initialTime);
      }
      this.dataManager.setOriginalLines(lines);
      this.rebuildLyricView(initialTime);
    }
    /**
     * 获取当前是否在播放
     * @returns 当前是否在播放
     */
    getIsPlaying() {
      return this.isPlaying;
    }
    /**
     * 设置当前播放进度，此时将会更新内部的歌词进度信息。
     *
     * 内部会根据调用间隔和播放进度自动决定如何滚动和显示歌词，所以这个的调用频率越快越准确越好。
     * 调用完成后，应每帧调用 {@link update} 方法来执行歌词动画效果。**此函数本身不会触发动画效果**。
     *
     * 当 `isSeek` 为 `true` 时，将触发重新排版，代价较高，因此请只在真正跳转时设为 `true`
     *
     * @param time 当前播放进度，单位为毫秒
     * @param isSeek 这个进度变化是否为跳转触发的
     */
    setCurrentTime(time, isSeek = false) {
      time = Math.round(time);
      const diff = this.timelineController.sync(time, isSeek);
      if (!diff.hasChanged) {
        return;
      }
      for (let i = 0; i < diff.removedHighlighted.length; i++) {
        this.currentLyricGroups[diff.removedHighlighted[i]]?.disable();
      }
      for (let i = 0; i < diff.addedHighlighted.length; i++) {
        this.currentLyricGroups[diff.addedHighlighted[i]]?.enable();
      }
      if (diff.isTimeJumped) {
        if (!this.scrollState.isTouchScrolled) {
          this.resetScroll();
        }
      }
      if (diff.isInterludeChanged || diff.isScrollToChanged || diff.isTimeJumped) {
        const isInterludeActive = !!this.timelineController.getSnapshot().activeInterlude;
        this.updateSpringParams(isInterludeActive);
      }
      this.calcLayout(isSeek ? LayoutReason.Seek : LayoutReason.PlaybackTick);
    }
    /**
     * 重新构建歌词行和时间状态
     *
     * 一般用于在调用 {@link setLyricProcessConfig} 更新配置后手动刷新视图，
     * 或在外部样式/DOM 结构发生改变后重置歌词视图
     *
     * @param initialTime 重建后对齐的初始时间（毫秒），默认使用当前播放进度
     */
    rebuildLyricView(initialTime = this.getCurrentTime()) {
      this.resetScroll();
      this.layoutState.alignTarget = { type: "line", index: 0 };
      for (const group of this.currentLyricGroups) {
        group.dispose();
      }
      this.currentLyricGroups = [];
      this.interludeDots.setInterlude(void 0);
      this.buildLyricGroups();
      this.currentLyricGroups.sort((a, b) => a.startTime - b.startTime);
      for (let i = 0; i < this.currentLyricGroups.length; i++) {
        this.lyricGroupIndexMap.set(this.currentLyricGroups[i], i);
      }
      const bounds = this.currentLyricGroups.map((group) => ({
        startTime: group.startTime,
        endTime: group.endTime
      }));
      this.timelineController.setTimeBounds(bounds);
      this.layoutCalculator.initHeights(
        this.currentLyricGroups.length,
        this.defaultLineHeight
      );
      this.setCurrentTime(initialTime, true);
      this.calcLayout(LayoutReason.RebuildView);
      if (false) {
        console.log("\u6B4C\u8BCD\u89C6\u56FE\u91CD\u5EFA\u5B8C\u6210", this);
      }
    }
    /**
     * 更新歌词纵向滚动动画的弹簧参数。
     *
     * 其策略为：
     * - seeking 或间奏时使用更稳定的固定参数
     * - 普通播放时根据相邻歌词的时间间隔动态调整 stiffness / damping
     */
    updateSpringParams(isInterludeActive) {
      if (!this.getEnableSpring() || this.currentLyricGroups.length === 0) {
        return;
      }
      const snapshot = this.timelineController.getSnapshot();
      const { scrollToIndex, isSeeking } = snapshot;
      const currentGroup = this.currentLyricGroups[scrollToIndex];
      const prevGroup = this.currentLyricGroups[scrollToIndex - 1];
      let interval;
      if (currentGroup && prevGroup) {
        interval = currentGroup.startTime - prevGroup.startTime;
      }
      const policy = getPosYSpringPolicy(isSeeking, isInterludeActive, interval);
      this.setLinePosYSpringParams(policy);
    }
    /**
     * 重新计算歌词行的几何排版坐标与视觉状态
     *
     * 此方法不会触发 DOM 强制重排
     *
     * 计算完成后，在每一帧调用 `update()` / `commitChanges()` 即可让歌词平滑移动至目标位置
     *
     * @internal 仅供内部和绑定包使用
     * @param reason 触发排版布局更新的原因场景
     */
    calcLayout(reason) {
      const strategy = LayoutReasonStrategyMap[reason];
      const snapshot = this.timelineController.getSnapshot();
      const interlude = snapshot.activeInterlude;
      const isInterludeFocused = snapshot.isFocusOnInterlude && !!interlude;
      const count = this.currentLyricGroups.length;
      const maxValidIndex = Math.max(0, count - 1);
      const clampLineIndex = (index) => count > 0 ? Math.min(Math.max(0, index), maxValidIndex) : 0;
      const safeScrollToIndex = clampLineIndex(snapshot.scrollToIndex);
      let focalTarget = {
        type: "line",
        index: safeScrollToIndex
      };
      if (this.scrollState.isAutoAlignSuspended) {
        const target = this.layoutState.alignTarget;
        if (target.type === "line") {
          focalTarget = { type: "line", index: clampLineIndex(target.index) };
        } else if (target.type === "interlude") {
          if (!isInterludeFocused) {
            focalTarget = {
              type: "line",
              index: clampLineIndex(target.anchorIndex + 1)
            };
          } else {
            focalTarget = target;
          }
        } else {
          focalTarget = target;
        }
      } else {
        if (isInterludeFocused && interlude) {
          focalTarget = {
            type: "interlude",
            anchorIndex: interlude.anchorLineIndex
          };
        } else if (snapshot.isEndOfSong) {
          if (this.hasBottomContent) {
            focalTarget = { type: "bottom" };
          } else if (count > 0) {
            focalTarget = { type: "line", index: count - 1 };
          }
        }
      }
      this.layoutState.alignTarget = focalTarget;
      const fontSize = this.baseFontSize || 24;
      const dotMargin = fontSize * 0.4;
      const totalInterludeHeight = this.layoutState.interludeDotsSize[1] + dotMargin * 2;
      const ctx = this.frameContext;
      ctx.containerHeight = this.size[1];
      ctx.target = focalTarget;
      ctx.bottomLineHeight = this.bottomLine.lineSize[1] || 0;
      const interludeAnchorIndex = LayoutCalculator.resolveInterludeAnchorIndex(
        interlude,
        focalTarget
      );
      if (interludeAnchorIndex !== void 0) {
        ctx.interlude = ctx.interlude || { totalHeight: 0, anchorIndex: 0 };
        ctx.interlude.totalHeight = totalInterludeHeight;
        ctx.interlude.anchorIndex = interludeAnchorIndex;
      } else {
        ctx.interlude = void 0;
      }
      const { bounds, session } = this.layoutCalculator.beginFrame(
        ctx,
        this.layoutConfig
      );
      ctx.scrollOffset = this.scrollEngine.updateBoundary(bounds.min, bounds.max);
      const result = this.layoutCalculator.commit(session, ctx.scrollOffset);
      if (result.hasInterlude && interlude) {
        const nextLineIndex = interlude.anchorLineIndex + 1;
        const nextGroup = this.currentLyricGroups[nextLineIndex];
        const isNextDuet = nextGroup?.mainLine.getLine().isDuet ?? false;
        const targetX = isNextDuet ? this.size[0] - this.layoutState.interludeDotsSize[0] : 0;
        this.interludeDots.setTransform(targetX, result.interludeY + dotMargin);
        const shouldResetAnimation = snapshot.isSeeking || strategy.resetInterlude;
        this.interludeDots.setInterlude(
          [interlude.startTime, interlude.endTime],
          snapshot.currentTime,
          shouldResetAnimation
        );
      } else {
        this.interludeDots.setInterlude(void 0);
      }
      const fallbackFocusIndex = snapshot.scrollToIndex;
      const latestIndex = snapshot.latestHighlightedIndex ?? fallbackFocusIndex;
      const activeCount = result.lineCount;
      let delay = 0;
      let baseDelay = strategy.disableStagger ? 0 : 0.05;
      for (let i = 0; i < activeCount; i++) {
        const group = this.currentLyricGroups[i];
        const instruction = result.lineInstructions[i];
        const curPos = instruction.y;
        const hasHighlighted = snapshot.highlightedGroups.has(i);
        const isActive = hasHighlighted || i >= snapshot.scrollToIndex && i < latestIndex;
        const blurFocusIndex = snapshot.isTimelineEmpty ? fallbackFocusIndex : latestIndex;
        let blurLevel = 0;
        let targetOpacity = 1;
        if (!instruction.isInViewport) {
          blurLevel = this.enableBlur ? 5 : 0;
          targetOpacity = 0;
        } else {
          if (this.enableBlur && !this.scrollState.isTouchScrolled && !isActive) {
            blurLevel = 1;
            if (i < snapshot.scrollToIndex) {
              blurLevel += Math.abs(snapshot.scrollToIndex - i) + 1;
            } else {
              blurLevel += Math.abs(i - blurFocusIndex);
            }
            if (window.innerWidth <= 1024) {
              blurLevel *= 0.8;
            }
          }
          if (this.hidePassedLines) {
            if (i < (interlude ? interlude.anchorLineIndex + 1 : snapshot.scrollToIndex) && this.isPlaying) {
              targetOpacity = 1e-4;
            } else if (hasHighlighted) {
              targetOpacity = 0.85;
            } else {
              targetOpacity = this.isNonDynamic ? 0.2 : 1;
            }
          } else if (hasHighlighted) {
            targetOpacity = 0.85;
          } else {
            targetOpacity = this.isNonDynamic ? 0.2 : 1;
          }
        }
        const scaleImmediate = strategy.snapPosY && !this.scrollState.isAutoAlignSuspended;
        group.setTransform(
          curPos,
          strategy.snapPosY,
          delay,
          isActive,
          targetOpacity,
          blurLevel,
          scaleImmediate
        );
        const lineH = instruction.height;
        if (curPos + lineH >= 0 && !snapshot.isSeeking) {
          delay += baseDelay;
          if (i >= snapshot.scrollToIndex) baseDelay /= 1.05;
        }
      }
      const isBottomFocused = focalTarget.type === "bottom";
      this.bottomLine.setFocused(isBottomFocused);
      let finalBottomBlur = 0;
      const bottomBlurFocusIndex = snapshot.isTimelineEmpty ? fallbackFocusIndex : latestIndex;
      if (!result.isBottomLineInViewport) {
        finalBottomBlur = this.enableBlur ? 5 : 0;
      } else if (this.enableBlur && !this.scrollState.isAutoAlignSuspended && !isBottomFocused) {
        finalBottomBlur = 1;
        if (activeCount < snapshot.scrollToIndex) {
          finalBottomBlur += Math.abs(snapshot.scrollToIndex - activeCount) + 1;
        } else {
          finalBottomBlur += Math.abs(activeCount - bottomBlurFocusIndex);
        }
        if (window.innerWidth <= 1024) finalBottomBlur *= 0.8;
      }
      this.bottomLine.setTransform(
        0,
        result.bottomLineY,
        finalBottomBlur,
        strategy.snapPosY,
        delay
      );
    }
    /**
     * 设置所有歌词行在横坐标上的弹簧属性，包括重量、弹力和阻力。
     *
     * @param params 需要设置的弹簧属性，提供的属性将会覆盖原来的属性，未提供的属性将会保持原样
     * @deprecated 考虑到横向弹簧效果并不常见，所以这个函数将会在未来的版本中移除
     */
    setLinePosXSpringParams(_params = {}) {
    }
    /**
     * 设置所有歌词行在​纵坐标上的弹簧属性，包括重量、弹力和阻力。
     *
     * @param params 需要设置的弹簧属性，提供的属性将会覆盖原来的属性，未提供的属性将会保持原样
     */
    setLinePosYSpringParams(params = {}) {
      this.posYSpringParams = {
        ...this.posYSpringParams,
        ...params
      };
      this.bottomLine.lineTransforms.posY.updateParams(this.posYSpringParams);
      for (const group of this.currentLyricGroups) {
        group.posY.updateParams(this.posYSpringParams);
        group.bgSlideY.updateParams(this.posYSpringParams);
      }
    }
    /**
     * 设置所有歌词行在​缩放大小上的弹簧属性，包括重量、弹力和阻力。
     *
     * @param params 需要设置的弹簧属性，提供的属性将会覆盖原来的属性，未提供的属性将会保持原样
     */
    setLineScaleSpringParams(params = {}) {
      this.scaleSpringParams = {
        ...this.scaleSpringParams,
        ...params
      };
      this.scaleForBGSpringParams = {
        ...this.scaleForBGSpringParams,
        ...params
      };
      for (const group of this.currentLyricGroups) {
        group.mainLine.lineTransforms.scale.updateParams(this.scaleSpringParams);
        group.bgLine?.lineTransforms.scale.updateParams(
          this.scaleForBGSpringParams
        );
      }
    }
    /**
     * 暂停部分效果演出，目前会暂停播放间奏点的动画，且将背景歌词显示出来
     */
    pause() {
      this.interludeDots.pause();
      if (this.isPlaying) {
        this.isPlaying = false;
        this.calcLayout(LayoutReason.ConfigChange);
      }
    }
    /**
     * 恢复部分效果演出，目前会恢复播放间奏点的动画
     */
    resume() {
      this.interludeDots.resume();
      if (!this.isPlaying) {
        this.isPlaying = true;
        this.calcLayout(LayoutReason.ConfigChange);
      }
    }
    /**
     * 更新动画，这个函数应该被逐帧调用或者在以下情况下调用一次：
     *
     * 1. 刚刚调用完设置歌词函数的时候
     * @param delta 距离上一次被调用到现在的时长，单位为毫秒（可为浮点数）
     */
    update(delta = 0) {
      this.bottomLine.update(delta / 1e3);
      this.interludeDots.update(delta);
    }
    onResize() {
    }
    /**
     * 获取一个特殊的底栏元素，默认是空白的，可以往内部添加任意元素
     *
     * 这个元素始终在歌词的底部，可以用于显示歌曲创作者等信息
     *
     * 但是请勿删除该元素，只能在内部存放元素
     *
     * @returns 一个元素，可以往内部添加任意元素
     */
    getBottomLineElement() {
      return this.bottomLine.getElement();
    }
    /**
     * 重置用户滚动状态并恢复自动对齐
     *
     * 一个典型的使用场景是在用户滚动完毕、但歌词未自动归位时立刻归位
     */
    resetScroll() {
      this.scrollEngine.resetScroll(0);
      this.scrollState.isAutoAlignSuspended = false;
      this.scrollState.isTouchScrolled = false;
    }
    /**
     * 获取当前播放的、未经过优化和掩码处理的歌词数组
     *
     * 一般和最后调用 `setLyricLines` 给予的参数一样
     * @returns 当前歌词数组
     */
    getLyricLines() {
      return this.dataManager.getRawLines();
    }
    /**
     * 获取当前歌词的播放位置
     *
     * 一般和最后调用 `setCurrentTime` 给予的参数一样
     * @returns 当前播放位置
     */
    getCurrentTime() {
      return this.timelineController.getSnapshot().currentTime;
    }
    /**
     * 设置是否让背景人声行始终后置显示
     *
     * 默认情况下，如果背景歌词开始时间早于主歌词，会在主歌词上方展示；
     * 如果设置为 `true`，则无论时间顺序如何，背景歌词都会始终在主歌词下方展示
     * @param enable 是否启用始终后置
     */
    setAlwaysPostpositionBackground(enable) {
      if (this.alwaysPostpositionBackground === enable) {
        return;
      }
      this.alwaysPostpositionBackground = enable;
      this.rebuildLyricLines();
      this.calcLayout(LayoutReason.ConfigChange);
    }
    /** 获取当前是否设置了让背景人声行始终后置显示 */
    getAlwaysPostpositionBackground() {
      return this.alwaysPostpositionBackground;
    }
    getElement() {
      return this.element;
    }
    dispose() {
      this.scrollEngine.dispose();
      this.element.remove();
      this.bottomLineObserver.disconnect();
      window.removeEventListener("pageshow", this.onPageShow);
      window.removeEventListener("pagehide", this.onPageHide);
    }
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/base/group.ts
  var LyricLineGroupBase = class {
    constructor(mainLine, bgLine) {
      this.mainLine = mainLine;
      this.bgLine = bgLine;
    }
    mainLine;
    bgLine;
    posY = new Spring(0);
    bgSlideY = new Spring(-80);
    top = 0;
    delay = 0;
    isActive = false;
    opacity = 1;
    blur = 0;
    isBgFirst = false;
    isUiDirty = true;
    get startTime() {
      return this.mainLine.getLine().startTime;
    }
    get endTime() {
      return this.mainLine.getLine().endTime;
    }
    onLineSizeChange(size) {
      this.mainLine.onLineSizeChange(size);
      this.bgLine?.onLineSizeChange(size);
    }
    setTransform(top, immediate, delay, isActive, opacity, blur, scaleImmediate = immediate) {
      this.top = top;
      this.delay = delay;
      this.isActive = isActive;
      this.opacity = opacity;
      this.blur = blur;
      this.setLineTransformations(scaleImmediate, delay);
      const enableSpring = this.lyricPlayer.getEnableSpring();
      const alwaysPostposition = this.lyricPlayer.getAlwaysPostpositionBackground();
      const shouldBgFirst = alwaysPostposition ? false : this.isBgFirst;
      const hiddenSlideY = shouldBgFirst ? 80 : -80;
      const isPlaying = this.lyricPlayer.getIsPlaying();
      const targetBgSlideY = isActive || !isPlaying ? 0 : hiddenSlideY;
      if (immediate || !enableSpring) {
        this.posY.setPosition(top);
        this.bgSlideY.setPosition(targetBgSlideY);
      } else {
        this.posY.setTargetPosition(top, delay);
        this.bgSlideY.setTargetPosition(targetBgSlideY, delay);
      }
      this.isUiDirty = true;
    }
    setLineTransformations(immediate, delay) {
      const enableScale = this.lyricPlayer.getEnableScale();
      const isPlaying = this.lyricPlayer.getIsPlaying();
      const renderMode = this.isActive ? LyricLineRenderMode.GRADIENT : LyricLineRenderMode.SOLID;
      const SCALE_ASPECT = enableScale ? 97 : 100;
      let mainScale = 100;
      if (!this.isActive && isPlaying) {
        mainScale = SCALE_ASPECT;
      }
      this.mainLine.setTransform(mainScale, 1, 0, immediate, delay, renderMode);
      let bgScale = 100;
      if (!this.isActive && isPlaying) {
        bgScale = 75;
      }
      this.bgLine?.setTransform(bgScale, 1, 0, immediate, delay, renderMode);
    }
    update(delta) {
      if (this.lyricPlayer.getEnableSpring()) {
        const posMoving = !this.posY.arrived();
        const bgMoving = !this.bgSlideY.arrived();
        this.posY.update(delta);
        this.bgSlideY.update(delta);
        if (posMoving || bgMoving) {
          this.isUiDirty = true;
        }
      }
      this.mainLine.update(delta);
      this.bgLine?.update(delta);
    }
    commitChanges() {
      if (!this.isInSight) return;
      if (this.isUiDirty) {
        this.renderStyles();
        this.isUiDirty = false;
      }
      this.mainLine.commitChanges();
      this.bgLine?.commitChanges();
    }
    rebuildAllLines() {
      this.mainLine.rebuildElement();
      this.bgLine?.rebuildElement();
    }
    enable(time, shouldPlay) {
      this.mainLine.enable(time, shouldPlay);
      this.bgLine?.enable(time, shouldPlay);
    }
    disable() {
      this.mainLine.disable();
      this.bgLine?.disable();
    }
    dispose() {
      this.mainLine.dispose();
      this.bgLine?.dispose();
    }
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/dom/lyric-group.ts
  var LyricLineGroup = class extends LyricLineGroupBase {
    constructor(lyricPlayer, mainLine) {
      super(mainLine);
      this.lyricPlayer = lyricPlayer;
      this.element = document.createElement("div");
      this.element.className = lyric_player_default.lyricLineWrapper;
      if (mainLine.getLine().isDuet) {
        this.element.classList.add(lyric_player_default.isDuetWrapper);
      }
      this.element.appendChild(mainLine.getElement());
      this.posY.setPosition(window.innerHeight * 2);
      lyricPlayer.resizeObserver.observe(this.element);
    }
    lyricPlayer;
    element;
    bgWrapper;
    lastIsActive;
    lastBgHeight = 0;
    lastBgIsHidden;
    lastYNum = -9999;
    lastOpacityNum = -1;
    lastBlurNum = -1;
    lastBgSlideYNum = -9999;
    getElement() {
      return this.element;
    }
    get isInSight() {
      const t = this.posY.getCurrentPosition();
      const index = this.lyricPlayer.currentLyricGroups.indexOf(this);
      const h = index !== -1 ? this.lyricPlayer.getLineHeight(index) : this.lyricPlayer.defaultLineHeight;
      const pb = this.lyricPlayer.size[1];
      const ov = this.lyricPlayer.getOverscanPx();
      return !(t > pb + h + ov || t < -h - ov);
    }
    show() {
      if (!this.element.parentElement) {
        const playerEl = this.lyricPlayer.getElement();
        const groups = this.lyricPlayer.currentLyricGroups;
        const myIndex = groups.indexOf(this);
        let referenceNode = null;
        if (myIndex !== -1) {
          for (let i = myIndex + 1; i < groups.length; i++) {
            if (groups[i].element.parentElement === playerEl) {
              referenceNode = groups[i].element;
              break;
            }
          }
        }
        playerEl.insertBefore(this.element, referenceNode);
        this.lyricPlayer.resizeObserver.observe(this.element);
        if (this.bgWrapper) {
          this.lyricPlayer.resizeObserver.observe(this.bgWrapper);
        }
      }
      this.mainLine.show();
      this.bgLine?.show();
    }
    hide() {
      if (this.element.parentElement) {
        this.lyricPlayer.resizeObserver.unobserve(this.element);
        if (this.bgWrapper) {
          this.lyricPlayer.resizeObserver.unobserve(this.bgWrapper);
        }
        this.element.remove();
      }
    }
    update(delta) {
      super.update(delta);
    }
    commitChanges() {
      if (this.isInSight) {
        this.show();
        super.commitChanges();
      } else {
        this.hide();
      }
    }
    onBgSizeChange(size) {
      if (this.bgWrapper && this.lastBgHeight !== size[1]) {
        this.lastBgHeight = size[1];
        this.lastBgSlideYNum = -9999;
        this.isUiDirty = true;
      }
    }
    addBgLine(bgLine) {
      if (this.bgLine) {
        this.bgLine.dispose();
      }
      if (this.bgWrapper) {
        this.bgWrapper.remove();
      }
      this.bgLine = bgLine;
      const bgStartTime = bgLine.getLine().words[0]?.startTime ?? bgLine.getLine().startTime;
      const mainStartTime = this.mainLine.getLine().words[0]?.startTime ?? this.mainLine.getLine().startTime;
      this.isBgFirst = bgStartTime < mainStartTime;
      if (this.mainLine.getLine().isDuet) {
        bgLine.getElement().classList.add(lyric_player_default.lyricDuetLine);
        this.element.classList.add(lyric_player_default.isDuetWrapper);
      }
      this.bgWrapper = document.createElement("div");
      this.bgWrapper.className = lyric_player_default.bgWrapper;
      this.bgWrapper.appendChild(bgLine.getElement());
      const alwaysPostposition = this.lyricPlayer.getAlwaysPostpositionBackground();
      const shouldBgFirst = !alwaysPostposition && this.isBgFirst;
      if (shouldBgFirst) {
        this.bgWrapper.classList.add(lyric_player_default.bgWrapperTop);
        this.element.insertBefore(this.bgWrapper, this.mainLine.getElement());
        this.bgSlideY.setPosition(80);
      } else {
        this.element.appendChild(this.bgWrapper);
      }
      this.lyricPlayer.lyricGroupElementMap.set(this.bgWrapper, this);
      if (this.element.parentElement) {
        this.lyricPlayer.resizeObserver.observe(this.bgWrapper);
      }
      this.lastBgHeight = this.bgWrapper.clientHeight || 0;
    }
    renderStyles() {
      const style = this.element.style;
      const currentY = this.posY.getCurrentPosition();
      if (Math.abs(currentY - this.lastYNum) >= 1e-3) {
        this.lastYNum = currentY;
        style.transform = `translateY(${currentY.toFixed(1)}px)`;
      }
      if (Math.abs(this.opacity - this.lastOpacityNum) >= 0.05) {
        this.lastOpacityNum = this.opacity;
        style.opacity = String(this.opacity);
      }
      const blurVal = Math.min(5, this.blur);
      if (Math.abs(blurVal - this.lastBlurNum) >= 0.05) {
        this.lastBlurNum = blurVal;
        style.filter = blurVal > 0.01 ? `blur(${blurVal.toFixed(2)}px)` : "none";
      }
      if (this.bgWrapper) {
        if (this.lastIsActive !== this.isActive) {
          this.lastIsActive = this.isActive;
          this.bgWrapper.classList.toggle(lyric_player_default.bgWrapperActive, this.isActive);
        }
        const bgStyle = this.bgWrapper.style;
        const slideY = this.bgSlideY.getCurrentPosition();
        if (Math.abs(slideY - this.lastBgSlideYNum) >= 1e-3) {
          this.lastBgSlideYNum = slideY;
          const activeProgress = clamp01(1 - Math.abs(slideY) / 80);
          const scaleStr = (0.8 + activeProgress * 0.2).toFixed(3);
          const alwaysPostposition = this.lyricPlayer.getAlwaysPostpositionBackground();
          const shouldBgFirst = !alwaysPostposition && this.isBgFirst;
          const translateYPx = slideY / 100 * this.lastBgHeight;
          if (shouldBgFirst) {
            const currentMarginTop = -this.lastBgHeight * (1 - activeProgress);
            bgStyle.marginTop = `${currentMarginTop.toFixed(1)}px`;
          } else {
            bgStyle.marginTop = "";
          }
          bgStyle.transform = `translateY(${translateYPx.toFixed(1)}px) scale(${scaleStr})`;
          const targetHiddenY = shouldBgFirst ? 80 : -80;
          const isHidden = Math.abs(slideY - targetHiddenY) < 0.1 && !this.isActive;
          if (this.lastBgIsHidden !== isHidden) {
            this.lastBgIsHidden = isHidden;
            this.bgWrapper.classList.toggle(lyric_player_default.bgWrapperHidden, isHidden);
          }
        }
      }
    }
    dispose() {
      super.dispose();
      this.lyricPlayer.resizeObserver.unobserve(this.element);
      if (this.bgWrapper) {
        this.lyricPlayer.lyricGroupElementMap.delete(this.bgWrapper);
        this.lyricPlayer.resizeObserver.unobserve(this.bgWrapper);
      }
      this.element.remove();
    }
  };

  // ../../../../../../../Code/applemusic-like-lyrics/node_modules/.pnpm/bezier-easing@3.0.1/node_modules/bezier-easing/src/index.js
  function LinearEasing(x) {
    return x;
  }
  var { cbrt, sqrt, PI: \u03C0 } = Math;
  var x2t = (x, a, b, c, d) => {
    const q = a + b * x;
    const s = q ** 2 + c;
    if (s > 0) {
      const root = sqrt(s);
      return cbrt(q + root) + cbrt(q - root) - d;
    }
    const l = cbrt(sqrt(q * q - s));
    const angle = q ? Math.atan(sqrt(-s) / q) : -\u03C0 / 2;
    let \u03C6;
    if (b < 0) {
      \u03C6 = (q > 0 ? 2 * \u03C0 : \u03C0) - angle;
    } else if (d < 0) {
      \u03C6 = (q > 0 ? 2 * \u03C0 : -3 * \u03C0) + angle;
    } else {
      \u03C6 = (q > 0 ? 0 : \u03C0) + angle;
    }
    return 2 * l * Math.cos(\u03C6 / 3) - d;
  };
  var Y = (t, ay, by, cy) => ((ay * t + 3 * by) * t + cy) * t;
  function bezier(mX1, mY1, mX2, mY2) {
    if (!(0 <= mX1 && mX1 <= 1 && 0 <= mX2 && mX2 <= 1)) {
      throw new Error("bezier x values must be in [0, 1] range");
    }
    if (mX1 === mY1 && mX2 === mY2) {
      return LinearEasing;
    }
    const a = 6 * (3 * mX1 - 3 * mX2 + 1);
    const b = 6 * (mX2 - 2 * mX1);
    const c = 3 * mX1;
    const a2 = a * a;
    const b2 = b * b;
    const d = b / a;
    const e = 3 * b * c / a2 - b2 * b / (a2 * a);
    const w1 = 2 * c / a - b2 / a2;
    const w = w1 * w1 * w1;
    const o = 3 / a;
    const ay = 3 * mY1 - 3 * mY2 + 1;
    const by = mY2 - 2 * mY1;
    const cy = 3 * mY1;
    const X2T = a ? x2t : LinearEasing;
    return function BezierEasing(x) {
      if (x === 0 || x === 1) {
        return x;
      }
      return Y(X2T(x, e, o, w, d), ay, by, cy);
    };
  }

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/utils/is-cjk.ts
  var isCJK = (char) => {
    return /^[\p{Unified_Ideograph}\u0800-\u9FFC]+$/u.test(char);
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/base/line.ts
  var LyricLineBase = class extends EventTarget {
    top = 0;
    scale = 1;
    blur = 0;
    opacity = 1;
    delay = 0;
    isUiDirty = true;
    lineTransforms = {
      scale: new Spring(100)
    };
    /**
     * 用于 CJK 词语边界检测的分词器
     */
    static wordSegmenter = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(void 0, { granularity: "word" }) : null;
    /**
     * Unicode 标准的全局 Grapheme Cluster 分词器
     * 用于正确处理 emoji、复合字符等
     */
    static graphemeSegmenter = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(void 0, { granularity: "grapheme" }) : null;
    setTransform(scale = this.scale, opacity = this.opacity, blur = this.blur, _immediate = false, delay = 0, _mode = LyricLineRenderMode.SOLID) {
      this.scale = scale;
      this.opacity = opacity;
      this.blur = blur;
      this.delay = delay;
      this.isUiDirty = true;
    }
    rebuildElement() {
    }
    /**
     * 判定歌词是否可以应用强调辉光效果
     *
     * 果子在对辉光效果的解释是一种强调（emphasized）效果
     *
     * 条件是一个单词时长大于等于 1s 且长度小于等于 7
     *
     * @param word 单词
     * @returns 是否可以应用强调辉光效果
     */
    static shouldEmphasize(word) {
      if (isCJK(word.word)) return word.endTime - word.startTime >= 1e3;
      return word.endTime - word.startTime >= 1e3 && word.word.trim().length <= 7 && word.word.trim().length > 1;
    }
    dispose() {
    }
  };

  // single-line-balancer.ts
  var LineBalancer = class {
    balanceLineBreaks() {
    }
    reset() {
    }
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/utils/lyric-split-words.ts
  var SPLIT_WHITESPACE_RE = /(\s+)/;
  var WHITESPACE_RE = /\s/g;
  function chunkAndSplitLyricWords(words) {
    const result = [];
    let currentGroup = [];
    const flushGroup = () => {
      if (currentGroup.length > 0) {
        result.push(
          currentGroup.length === 1 ? currentGroup[0] : [...currentGroup]
        );
        currentGroup = [];
      }
    };
    const processAtom = (atom) => {
      const isSpace = atom.word.trim().length === 0;
      const hasRuby = (atom.ruby?.length ?? 0) > 0;
      const isCJKChar = isCJK(atom.word);
      const isMergeable = !isSpace && !hasRuby && !isCJKChar;
      if (isMergeable) {
        currentGroup.push(atom);
      } else {
        flushGroup();
        result.push(atom);
      }
    };
    for (const w of words) {
      const content = w.word.trim();
      const isSpace = content.length === 0;
      const romanWord = w.romanWord ?? "";
      const obscene = w.obscene ?? false;
      const hasRuby = (w.ruby?.length ?? 0) > 0;
      if (isSpace) {
        processAtom({ ...w, obscene });
        continue;
      }
      if (hasRuby) {
        const leadingSpaceMatch = w.word.match(/^\s+/);
        const trailingSpaceMatch = w.word.match(/\s+$/);
        const leadingSpace = leadingSpaceMatch ? leadingSpaceMatch[0] : "";
        const trailingSpace = trailingSpaceMatch ? trailingSpaceMatch[0] : "";
        if (leadingSpace) {
          processAtom({
            word: leadingSpace,
            romanWord: "",
            startTime: w.startTime,
            endTime: w.startTime,
            obscene
          });
        }
        processAtom({
          ...w,
          word: content,
          obscene
        });
        if (trailingSpace) {
          processAtom({
            word: trailingSpace,
            romanWord: "",
            startTime: w.endTime,
            endTime: w.endTime,
            obscene
          });
        }
        continue;
      }
      const parts = w.word.split(SPLIT_WHITESPACE_RE).filter((p) => p.length > 0);
      const totalLength = w.word.replace(WHITESPACE_RE, "").length || 1;
      const timeSpan = w.endTime - w.startTime;
      const timePerUnit = timeSpan / totalLength;
      const wordParts = w.word.trim().split(/\s+/).filter((p) => p.length > 0);
      const romanTrimmed = romanWord.trim();
      const romanParts = romanTrimmed.length > 0 ? romanTrimmed.split(/\s+/).filter((p) => p.length > 0) : [];
      const isMatched = wordParts.length > 0 && wordParts.length === romanParts.length;
      let currentOffset = 0;
      let nonSpaceIndex = 0;
      for (const part of parts) {
        if (!part.trim()) {
          const startTime = w.startTime + currentOffset * timePerUnit;
          processAtom({
            word: part,
            romanWord: "",
            startTime,
            endTime: startTime,
            obscene
          });
          continue;
        }
        let partRomanWord = "";
        if (romanParts.length > 0) {
          if (isMatched) {
            partRomanWord = romanParts[nonSpaceIndex] ?? "";
          } else if (nonSpaceIndex === 0) {
            partRomanWord = romanWord;
          }
        }
        nonSpaceIndex++;
        if (isCJK(part) && part.length > 1 && romanTrimmed.length === 0) {
          const chars = part.split("");
          for (const char of chars) {
            const startTime = w.startTime + currentOffset * timePerUnit;
            processAtom({
              word: char,
              romanWord: "",
              startTime,
              endTime: startTime + timePerUnit,
              obscene
            });
            currentOffset += 1;
          }
        } else {
          const partRealLen = part.length;
          const startTime = w.startTime + currentOffset * timePerUnit;
          const duration = partRealLen * timePerUnit;
          processAtom({
            word: part,
            romanWord: partRomanWord,
            startTime,
            endTime: startTime + duration,
            obscene
          });
          currentOffset += partRealLen;
        }
      }
    }
    flushGroup();
    return result;
  }

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/utils/matrix.ts
  function createMatrix4() {
    return [
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1
    ];
  }
  function scaleMatrix4(m, scale = 1, origin = { x: 0, y: 0 }) {
    const [ox, oy] = [origin.x, origin.y];
    return [
      m[0] * scale,
      m[1] * scale,
      m[2] * scale,
      m[3],
      m[4] * scale,
      m[5] * scale,
      m[6] * scale,
      m[7],
      m[8] * scale,
      m[9] * scale,
      m[10] * scale,
      m[11],
      m[12] - ox * scale + ox,
      m[13] - oy * scale + oy,
      m[14],
      m[15]
    ];
  }
  function matrix4ToCSS(m, fractionDigits = 4) {
    const format = (n, _) => n.toFixed(fractionDigits);
    return `matrix3d(${m.map(format).join(", ")})`;
  }

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/dom/lyric-line.ts
  var ANIMATION_FRAME_QUANTITY = 32;
  var norNum = (min, max) => (x) => clamp01((x - min) / (max - min));
  var EMP_EASING_MID = 0.5;
  var beginNum = norNum(0, EMP_EASING_MID);
  var endNum = norNum(EMP_EASING_MID, 1);
  var bezIn = bezier(0.2, 0.4, 0.58, 1);
  var bezOut = bezier(0.3, 0, 0.58, 1);
  var makeEmpEasing = (mid) => {
    return (x) => x < mid ? bezIn(beginNum(x)) : 1 - bezOut(endNum(x));
  };
  function generateFadeGradient(width, padding = 0, bright = "rgba(0,0,0,var(--bright-mask-alpha, 1.0))", dark = "rgba(0,0,0,var(--dark-mask-alpha, 1.0))") {
    const totalAspect = 2 + width + padding;
    const widthInTotal = width / totalAspect;
    const leftPos = (1 - widthInTotal) / 2;
    return [
      `linear-gradient(to right,${bright} ${leftPos * 100}%,${dark} ${(leftPos + widthInTotal) * 100}%)`,
      totalAspect
    ];
  }
  var LyricLineEl = class extends LyricLineBase {
    constructor(lyricPlayer, lyricLine = {
      words: [],
      translatedLyric: "",
      romanLyric: "",
      startTime: 0,
      endTime: 0,
      isBG: false,
      isDuet: false
    }) {
      super();
      this.lyricPlayer = lyricPlayer;
      this.lyricLine = lyricLine;
      this.element.setAttribute("class", lyric_player_default.lyricLine);
      if (this.lyricLine.isBG) {
        this.element.classList.add(lyric_player_default.lyricBgLine);
      }
      if (this.lyricLine.isDuet) {
        this.element.classList.add(lyric_player_default.lyricDuetLine);
      }
      this.element.appendChild(document.createElement("div"));
      this.element.appendChild(document.createElement("div"));
      this.element.appendChild(document.createElement("div"));
      const main = this.element.children[0];
      const trans = this.element.children[1];
      const roman = this.element.children[2];
      main.setAttribute("class", lyric_player_default.lyricMainLine);
      trans.setAttribute("class", lyric_player_default.lyricSubLine);
      roman.setAttribute("class", lyric_player_default.lyricSubLine);
      if (LyricLineBase.wordSegmenter) {
        this.balancer = new LineBalancer(main);
      }
      this.rebuildStyle();
    }
    lyricPlayer;
    lyricLine;
    element = document.createElement("div");
    splittedWords = [];
    // 标记是否已经构建了行内的实际 DOM（单词与动画等）
    built = false;
    // 由 LyricPlayer 来设置
    lineSize = [0, 0];
    renderMode = LyricLineRenderMode.SOLID;
    lastScaleNum = -1;
    /**
     * 用于平衡换行、尽量减少各行长度差异的类
     */
    balancer;
    areWordsOnSameLine(word1, word2) {
      if (word1?.mainElement && word2?.mainElement) {
        const word1el = word1.mainElement;
        const word2el = word2.mainElement;
        const rect1 = word1el.getBoundingClientRect();
        const rect2 = word2el.getBoundingClientRect();
        const topDifference = Math.abs(rect1.top - rect2.top);
        return topDifference < 10;
      }
      return true;
    }
    isEnabled = false;
    async enable(maskAnimationTime = this.lyricPlayer.getCurrentTime(), shouldPlay = this.lyricPlayer.getIsPlaying()) {
      this.isEnabled = true;
      this.element.classList.add(lyric_player_default.active);
      const main = this.element.children[0];
      const relativeTime = clampPositive(
        maskAnimationTime - this.lyricLine.startTime
      );
      for (const word of this.splittedWords) {
        for (const a of word.elementAnimations) {
          a.currentTime = relativeTime;
          a.playbackRate = 1;
          const timing = a.effect?.getComputedTiming();
          const duration = Number(timing?.duration ?? 0);
          const delay = Number(timing?.delay ?? 0);
          const endTime = delay + duration;
          if (shouldPlay && relativeTime < endTime) a.play();
          else a.pause();
        }
        for (const a of word.maskAnimations) {
          const t = Math.min(this.totalDuration, relativeTime);
          a.currentTime = t;
          a.playbackRate = 1;
          const timing = a.effect?.getComputedTiming();
          const duration = Number(timing?.duration ?? 0);
          const delay = Number(timing?.delay ?? 0);
          const endTime = delay + duration;
          if (shouldPlay && t < endTime) a.play();
          else a.pause();
        }
      }
      main.classList.add(lyric_player_default.active);
    }
    disable() {
      this.isEnabled = false;
      this.element.classList.remove(lyric_player_default.active);
      this.setRenderMode(LyricLineRenderMode.SOLID);
      const main = this.element.children[0];
      for (const word of this.splittedWords) {
        for (const a of word.elementAnimations) {
          if (a.id === "float-word" || a.id.includes("emphasize-word-float-only")) {
            a.playbackRate = -1;
            a.play();
          }
        }
        for (const a of word.maskAnimations) {
          a.pause();
        }
      }
      main.classList.remove(lyric_player_default.active);
    }
    lastWord;
    async resume() {
      if (!this.isEnabled) return;
      for (const word of this.splittedWords) {
        for (const a of word.elementAnimations) {
          if (!this.lastWord || this.splittedWords.indexOf(this.lastWord) < this.splittedWords.indexOf(word)) {
            const timing = a.effect?.getComputedTiming();
            const duration = timing?.duration || 0;
            const delay = timing?.delay || 0;
            const endTime = delay + duration;
            const currentTime = a.currentTime || 0;
            if (a.playState !== "finished" && currentTime < endTime) {
              a.play();
            }
          }
        }
        for (const a of word.maskAnimations) {
          if (!this.lastWord || this.splittedWords.indexOf(this.lastWord) < this.splittedWords.indexOf(word)) {
            const timing = a.effect?.getComputedTiming();
            const duration = timing?.duration || 0;
            const delay = timing?.delay || 0;
            const endTime = delay + duration;
            const currentTime = a.currentTime || 0;
            if (a.playState !== "finished" && currentTime < endTime) {
              a.play();
            }
          }
        }
      }
    }
    async pause() {
      if (!this.isEnabled) return;
      for (const word of this.splittedWords) {
        for (const a of word.elementAnimations) {
          a.pause();
        }
        for (const a of word.maskAnimations) {
          a.pause();
        }
      }
    }
    setMaskAnimationState(maskAnimationTime = 0) {
      const t = maskAnimationTime - this.lyricLine.startTime;
      for (const word of this.splittedWords) {
        for (const a of word.maskAnimations) {
          a.currentTime = clamp(t, 0, this.totalDuration);
          a.playbackRate = 1;
          if (t >= 0 && t < this.totalDuration) a.play();
          else a.pause();
        }
      }
    }
    getLine() {
      return this.lyricLine;
    }
    // private _hide = true;
    show() {
      if (!this.built) {
        this.rebuildElement();
        this.built = true;
        this.updateMaskImageSync();
      }
    }
    rebuildStyle() {
      const style = this.element.style;
      const currentScale = this.lineTransforms.scale.getCurrentPosition() / 100;
      if (Math.abs(currentScale - this.lastScaleNum) >= 1e-4) {
        this.lastScaleNum = currentScale;
        style.transform = `scale(${currentScale.toFixed(3)})`;
      }
    }
    rebuildElement() {
      this.disposeElements();
      const main = this.element.children[0];
      const trans = this.element.children[1];
      const roman = this.element.children[2];
      if (this.lyricPlayer._getIsNonDynamic()) {
        main.textContent = this.lyricLine.words.map((w) => w.word).join("");
        this.setSubLinesText(trans, roman);
        return;
      }
      const chunkedWords = chunkAndSplitLyricWords(this.lyricLine.words);
      const hasRubyLine = this.lyricLine.words.some(
        (word) => (word.ruby?.length ?? 0) > 0
      );
      const hasRomanLine = this.lyricLine.words.some(
        (word) => (word.romanWord?.trim().length ?? 0) > 0
      );
      main.innerHTML = "";
      for (const chunk of chunkedWords) {
        this.buildWord(chunk, main, hasRubyLine, hasRomanLine);
      }
      this.setSubLinesText(trans, roman);
    }
    /** 设置翻译与音译行文本 */
    setSubLinesText(trans, roman) {
      trans.textContent = this.lyricLine.translatedLyric;
      roman.textContent = this.lyricLine.romanLyric;
    }
    getRubyCharCount(word) {
      return (word.ruby ?? []).reduce(
        (total, ruby) => total + ruby.word.length,
        0
      );
    }
    getRubySegments(word) {
      return (word.ruby ?? []).filter(
        (ruby) => (ruby?.word?.trim().length ?? 0) > 0
      );
    }
    createWord(word, shouldEmphasize, hasRubyLine, hasRomanLine) {
      const mainWordEl = document.createElement("span");
      const subElements = [];
      const romanWord = word.romanWord?.trim() ?? "";
      const wordContainer = hasRubyLine ? document.createElement("span") : mainWordEl;
      const wordTextContainer = hasRubyLine ? document.createElement("span") : wordContainer;
      if (hasRubyLine) {
        const rubyWordEl = document.createElement("span");
        const rubySegments = this.getRubySegments(word);
        for (const ruby of rubySegments) {
          const rubyPartEl = document.createElement("span");
          rubyPartEl.textContent = ruby.word;
          rubyPartEl.dataset.startTime = String(ruby.startTime);
          rubyPartEl.dataset.endTime = String(ruby.endTime);
          rubyWordEl.appendChild(rubyPartEl);
        }
        rubyWordEl.classList.add(lyric_player_default.rubyWord);
        mainWordEl.classList.add(lyric_player_default.wordWithRuby);
        wordContainer.classList.add(lyric_player_default.wordBody);
        wordTextContainer.classList.add(lyric_player_default.rubyBaseWord);
        wordContainer.appendChild(wordTextContainer);
        mainWordEl.appendChild(rubyWordEl);
        mainWordEl.appendChild(wordContainer);
      }
      const displayWord = word.word;
      if (shouldEmphasize) {
        mainWordEl.classList.add(lyric_player_default.emphasize);
        const trimmedWord = displayWord.trim();
        if (LyricLineBase.graphemeSegmenter) {
          for (const { segment } of LyricLineBase.graphemeSegmenter.segment(
            trimmedWord
          )) {
            const charEl = document.createElement("span");
            charEl.textContent = segment;
            subElements.push(charEl);
            wordTextContainer.appendChild(charEl);
          }
        } else {
          for (const segment of Array.from(trimmedWord)) {
            const charEl = document.createElement("span");
            charEl.textContent = segment;
            subElements.push(charEl);
            wordTextContainer.appendChild(charEl);
          }
        }
      } else {
        if (hasRomanLine) {
          const wordEl = document.createElement("div");
          wordEl.textContent = displayWord.trim();
          wordTextContainer.appendChild(wordEl);
        } else if (romanWord.length === 0) {
          wordTextContainer.textContent = displayWord.trim();
        }
      }
      if (hasRomanLine) {
        const romanWordEl = document.createElement("div");
        romanWordEl.textContent = romanWord.length > 0 ? romanWord : "\xA0";
        romanWordEl.classList.add(lyric_player_default.romanWord);
        wordContainer.appendChild(romanWordEl);
      }
      const realWord = {
        ...word,
        mainElement: mainWordEl,
        subElements,
        elementAnimations: [this.initFloatAnimation(word, mainWordEl)],
        maskAnimations: [],
        width: 0,
        height: 0,
        padding: 0,
        shouldEmphasize
      };
      return realWord;
    }
    buildWord(input, main, hasRubyLine, hasRomanLine) {
      const chunk = Array.isArray(input) ? input : [input];
      if (chunk.length === 0) return;
      const isPureSpace = chunk.every((w) => !w.word.trim());
      if (isPureSpace) {
        const textContent = chunk.map((w) => w.word).join("");
        main.appendChild(document.createTextNode(textContent));
        return;
      }
      const merged = chunk.reduce(
        (a, b) => {
          a.endTime = Math.max(a.endTime, b.endTime);
          a.startTime = Math.min(a.startTime, b.startTime);
          a.word += b.word;
          return a;
        },
        {
          word: "",
          romanWord: "",
          startTime: Number.POSITIVE_INFINITY,
          endTime: Number.NEGATIVE_INFINITY,
          wordType: "normal",
          obscene: false
        }
      );
      let emp = chunk.some((word) => LyricLineBase.shouldEmphasize(word));
      if (!isCJK(merged.word)) {
        emp = emp || LyricLineBase.shouldEmphasize(merged);
      }
      const wrapperWordEl = document.createElement("span");
      wrapperWordEl.classList.add(lyric_player_default.emphasizeWrapper);
      const characterElements = [];
      for (const word of chunk) {
        if (!word.word.trim()) {
          wrapperWordEl.appendChild(document.createTextNode(word.word));
          continue;
        }
        const realWord = this.createWord(word, emp, hasRubyLine, hasRomanLine);
        if (emp) {
          characterElements.push(...realWord.subElements);
        }
        this.splittedWords.push(realWord);
        wrapperWordEl.appendChild(realWord.mainElement);
      }
      if (emp && this.splittedWords.length > 0) {
        const lastWordOfChunk = this.splittedWords[this.splittedWords.length - 1];
        const rubyCharCount = chunk.reduce(
          (total, word) => total + this.getRubyCharCount(word),
          0
        );
        lastWordOfChunk.elementAnimations.push(
          ...this.initEmphasizeAnimation(
            merged,
            characterElements,
            merged.endTime - merged.startTime,
            merged.startTime - this.lyricLine.startTime,
            rubyCharCount
          )
        );
      }
      main.appendChild(wrapperWordEl);
    }
    initFloatAnimation(word, wordEl) {
      const delay = word.startTime - this.lyricLine.startTime;
      const duration = Math.max(1e3, word.endTime - word.startTime);
      let up = 0.05;
      if (this.lyricLine.isBG) {
        up *= 2;
      }
      const a = wordEl.animate(
        [
          {
            transform: "translateY(0px)"
          },
          {
            transform: `translateY(${-up}em)`
          }
        ],
        {
          duration: Number.isFinite(duration) ? duration : 0,
          delay: Number.isFinite(delay) ? delay : 0,
          id: "float-word",
          composite: "add",
          fill: "both",
          easing: "ease-out"
        }
      );
      a.pause();
      return a;
    }
    // 按照原 Apple Music 参考，强调效果只应用缩放、轻微左右位移和辉光效果，原主要的悬浮位移效果不变
    // 为了避免产生锯齿抖动感，使用 matrix3d 来实现缩放和位移
    initEmphasizeAnimation(word, characterElements, duration, delay, rubyCharCount) {
      const de = clampPositive(delay);
      let du = Math.max(1e3, duration);
      const anchorCharCount = rubyCharCount > 0 ? rubyCharCount : Math.max(1, characterElements.length);
      let result = [];
      let amount = du / 2e3;
      amount = amount > 1 ? Math.sqrt(amount) : amount ** 3;
      let blur = du / 3e3;
      blur = blur > 1 ? Math.sqrt(blur) : blur ** 3;
      amount *= 0.6;
      blur *= 0.5;
      if (this.lyricLine.words.length > 0 && word.word.includes(
        this.lyricLine.words[this.lyricLine.words.length - 1].word
      )) {
        amount *= 1.6;
        blur *= 1.5;
        du *= 1.2;
      }
      amount = Math.min(1.2, amount);
      blur = Math.min(0.8, blur);
      const animateDu = Number.isFinite(du) ? du : 0;
      const empEasing = makeEmpEasing(EMP_EASING_MID);
      result = characterElements.flatMap((el, i, arr) => {
        const wordDe = de + du / 2.5 / anchorCharCount * i;
        const result2 = [];
        const frames = new Array(ANIMATION_FRAME_QUANTITY).fill(0).map((_, j) => {
          const x = (j + 1) / ANIMATION_FRAME_QUANTITY;
          const transX = empEasing(x);
          const glowLevel = empEasing(x) * blur;
          const mat = scaleMatrix4(createMatrix4(), 1 + transX * 0.1 * amount);
          const offsetX = -transX * 0.03 * amount * (arr.length / 2 - i);
          const offsetY = -transX * 0.025 * amount;
          return {
            offset: x,
            transform: `${matrix4ToCSS(
              mat,
              4
            )} translate(${offsetX}em, ${offsetY}em)`,
            textShadow: `0 0 ${Math.min(
              0.3,
              blur * 0.3
            )}em rgba(255, 255, 255, ${glowLevel})`
          };
        });
        const glow = el.animate(frames, {
          duration: animateDu,
          delay: Number.isFinite(wordDe) ? wordDe : 0,
          id: `emphasize-word-${el.textContent}-${i}`,
          iterations: 1,
          composite: "replace",
          fill: "both"
        });
        glow.onfinish = () => {
          glow.pause();
        };
        glow.pause();
        result2.push(glow);
        const floatFrame = new Array(ANIMATION_FRAME_QUANTITY).fill(0).map((_, j) => {
          const x = (j + 1) / ANIMATION_FRAME_QUANTITY;
          let y = Math.sin(x * Math.PI);
          if (this.lyricLine.isBG) {
            y *= 2;
          }
          return {
            offset: x,
            transform: `translateY(${-y * 0.05}em)`
          };
        });
        const float = el.animate(floatFrame, {
          duration: animateDu * 1.4,
          delay: Number.isFinite(wordDe) ? wordDe - 400 : 0,
          id: "emphasize-word-float",
          iterations: 1,
          composite: "add",
          fill: "both"
        });
        float.onfinish = () => {
          float.pause();
        };
        float.pause();
        result2.push(float);
        return result2;
      });
      return result;
    }
    get totalDuration() {
      return this.lyricLine.endTime - this.lyricLine.startTime;
    }
    onLineSizeChange(_size) {
      this.updateMaskImageSync();
    }
    updateMaskImageSync() {
      for (const word of this.splittedWords) {
        const el = word.mainElement;
        if (el) {
          word.padding = Number.parseFloat(getComputedStyle(el).paddingLeft);
          word.width = el.clientWidth - word.padding * 2;
          word.height = el.clientHeight - word.padding * 2;
        } else {
          word.width = 0;
          word.height = 0;
          word.padding = 0;
        }
      }
      if (this.balancer && LyricLineBase.wordSegmenter) {
        this.balancer.balanceLineBreaks(
          this.lyricPlayer._getIsNonDynamic(),
          this.splittedWords.length > 0,
          LyricLineBase.wordSegmenter
        );
      }
      if (this.lyricPlayer.supportMaskImage) {
        this.generateWebAnimationBasedMaskImage();
      } else {
        this.generateCalcBasedMaskImage();
      }
      if (this.isEnabled) {
        const isPlayerRunning = this.lyricPlayer.getIsPlaying?.() ?? true;
        this.enable(this.lyricPlayer.getCurrentTime(), isPlayerRunning);
      }
    }
    generateCalcBasedMaskImage() {
      for (const word of this.splittedWords) {
        const wordEl = word.mainElement;
        if (wordEl) {
          word.width = wordEl.clientWidth;
          word.height = wordEl.clientHeight;
          const fadeWidth = word.height * this.lyricPlayer.getWordFadeWidth();
          const [maskImage, totalAspect] = generateFadeGradient(
            fadeWidth / word.width
          );
          const totalAspectStr = `${totalAspect * 100}% 100%`;
          if (this.lyricPlayer.supportMaskImage) {
            wordEl.style.maskImage = maskImage;
            wordEl.style.maskRepeat = "no-repeat";
            wordEl.style.maskOrigin = "left";
            wordEl.style.maskSize = totalAspectStr;
          } else {
            wordEl.style.webkitMaskImage = maskImage;
            wordEl.style.webkitMaskRepeat = "no-repeat";
            wordEl.style.webkitMaskOrigin = "left";
            wordEl.style.webkitMaskSize = totalAspectStr;
          }
          const w = word.width + fadeWidth;
          const maskPos = `clamp(${-w}px,calc(${-w}px + (var(--amll-player-time) - ${word.startTime})*${w / Math.abs(word.endTime - word.startTime)}px),0px) 0px, left top`;
          wordEl.style.maskPosition = maskPos;
          wordEl.style.webkitMaskPosition = maskPos;
        }
      }
    }
    generateWebAnimationBasedMaskImage() {
      const totalFadeDuration = Math.max(
        0,
        ...this.splittedWords.map((w) => w.endTime),
        this.lyricLine.endTime
      ) - this.lyricLine.startTime;
      this.splittedWords.forEach((word, i) => {
        const wordEl = word.mainElement;
        if (wordEl) {
          const fadeWidth = word.height * this.lyricPlayer.getWordFadeWidth();
          const [maskImage, totalAspect] = generateFadeGradient(
            fadeWidth / (word.width + word.padding * 2)
          );
          const totalAspectStr = `${totalAspect * 100}% 100%`;
          if (this.lyricPlayer.supportMaskImage) {
            wordEl.style.maskImage = maskImage;
            wordEl.style.maskRepeat = "no-repeat";
            wordEl.style.maskOrigin = "left";
            wordEl.style.maskSize = totalAspectStr;
          } else {
            wordEl.style.webkitMaskImage = maskImage;
            wordEl.style.webkitMaskRepeat = "no-repeat";
            wordEl.style.webkitMaskOrigin = "left";
            wordEl.style.webkitMaskSize = totalAspectStr;
          }
          const widthBeforeSelf = this.splittedWords.slice(0, i).reduce((a, b) => a + b.width, 0) + (this.splittedWords[0] ? fadeWidth : 0);
          const minOffset = -(word.width + word.padding * 2 + fadeWidth);
          const clampOffset = (x) => clamp(x, minOffset, 0);
          let curPos = -widthBeforeSelf - word.width - word.padding - fadeWidth;
          let timeOffset = 0;
          const frames = [];
          let lastPos = curPos;
          let lastTime = 0;
          const pushFrame = () => {
            const moveOffset = curPos - lastPos;
            const time = clamp01(timeOffset);
            const duration = time - lastTime;
            const d = Math.abs(duration / moveOffset);
            if (curPos > minOffset && lastPos < minOffset) {
              const staticTime = Math.abs(lastPos - minOffset) * d;
              const value2 = `${clampOffset(lastPos)}px 0`;
              const frame3 = {
                offset: lastTime + staticTime,
                maskPosition: value2
              };
              frames.push(frame3);
            }
            if (curPos > 0 && lastPos < 0) {
              const staticTime = Math.abs(lastPos) * d;
              const value2 = `${clampOffset(curPos)}px 0`;
              const frame3 = {
                offset: lastTime + staticTime,
                maskPosition: value2
              };
              frames.push(frame3);
            }
            const value = `${clampOffset(curPos)}px 0`;
            const frame2 = {
              offset: time,
              maskPosition: value
            };
            frames.push(frame2);
            lastPos = curPos;
            lastTime = time;
          };
          pushFrame();
          let lastTimeStamp = 0;
          this.splittedWords.forEach((otherWord, j) => {
            {
              const curTimeStamp = otherWord.startTime - this.lyricLine.startTime;
              const staticDuration = curTimeStamp - lastTimeStamp;
              timeOffset += staticDuration / totalFadeDuration;
              if (staticDuration > 0) pushFrame();
              lastTimeStamp = curTimeStamp;
            }
            {
              const fadeDuration = clampPositive(
                otherWord.endTime - otherWord.startTime
              );
              const rubySegments = this.getRubySegments(otherWord);
              const rubyCharCount = rubySegments.reduce(
                (total, ruby) => total + ruby.word.length,
                0
              );
              if (rubyCharCount > 0) {
                const widthPerChar = otherWord.width / rubyCharCount;
                let charIndex = 0;
                for (const ruby of rubySegments) {
                  const rubyStartTime = Number.isFinite(ruby.startTime) ? ruby.startTime : otherWord.startTime;
                  const rubyEndTime = Number.isFinite(ruby.endTime) ? ruby.endTime : otherWord.endTime;
                  const rubyStart = Math.max(rubyStartTime, otherWord.startTime);
                  const rubyEnd = Math.min(
                    Math.max(rubyEndTime, rubyStart),
                    otherWord.endTime
                  );
                  const rubyStartStamp = rubyStart - this.lyricLine.startTime;
                  const rubyStaticDuration = rubyStartStamp - lastTimeStamp;
                  timeOffset += rubyStaticDuration / totalFadeDuration;
                  if (rubyStaticDuration > 0) pushFrame();
                  lastTimeStamp = rubyStartStamp;
                  const rubyDuration = clampPositive(rubyEnd - rubyStart);
                  const perCharDuration = rubyDuration / ruby.word.length;
                  for (let rubyCharIndex = 0; rubyCharIndex < ruby.word.length; rubyCharIndex++) {
                    timeOffset += perCharDuration / totalFadeDuration;
                    curPos += widthPerChar;
                    if (j === 0 && charIndex === 0) {
                      curPos += fadeWidth * 1.5;
                    }
                    if (j === this.splittedWords.length - 1 && charIndex === rubyCharCount - 1) {
                      curPos += fadeWidth * 0.5;
                    }
                    if (perCharDuration > 0) pushFrame();
                    lastTimeStamp += perCharDuration;
                    charIndex++;
                  }
                }
                const wordEndStamp = Math.max(
                  otherWord.endTime - this.lyricLine.startTime,
                  lastTimeStamp
                );
                const wordTailDuration = wordEndStamp - lastTimeStamp;
                timeOffset += wordTailDuration / totalFadeDuration;
                if (wordTailDuration > 0) pushFrame();
                lastTimeStamp = wordEndStamp;
              } else {
                const segmentCount = 1;
                const segmentWidth = otherWord.width / segmentCount;
                const segmentDuration = fadeDuration / segmentCount;
                for (let segmentIndex = 0; segmentIndex < segmentCount; segmentIndex++) {
                  timeOffset += segmentDuration / totalFadeDuration;
                  curPos += segmentWidth;
                  if (j === 0 && segmentIndex === 0) {
                    curPos += fadeWidth * 1.5;
                  }
                  if (j === this.splittedWords.length - 1 && segmentIndex === segmentCount - 1) {
                    curPos += fadeWidth * 0.5;
                  }
                  if (segmentDuration > 0) pushFrame();
                  lastTimeStamp += segmentDuration;
                }
              }
            }
          });
          for (const a of word.maskAnimations) {
            a.cancel();
          }
          try {
            const ani = wordEl.animate(frames, {
              duration: totalFadeDuration || 1,
              id: `fade-word-${word.word}-${i}`,
              fill: "both"
            });
            ani.pause();
            word.maskAnimations = [ani];
          } catch (err) {
            console.warn("\u5E94\u7528\u6E10\u53D8\u52A8\u753B\u53D1\u751F\u9519\u8BEF", frames, totalFadeDuration, err);
          }
        }
      });
    }
    getElement() {
      return this.element;
    }
    setRenderMode(mode) {
      if (this.renderMode === mode) return;
      this.renderMode = mode;
      this.element.classList.toggle(
        lyric_player_default.gradientMask,
        mode === LyricLineRenderMode.GRADIENT
      );
    }
    setTransform(scale = this.scale, opacity = 1, blur = 0, immediate = false, delay = 0, mode = LyricLineRenderMode.SOLID) {
      super.setTransform(scale, opacity, blur, immediate, delay);
      this.setRenderMode(mode);
      this.top = 0;
      this.scale = scale;
      this.delay = delay * 1e3 | 0;
      const enableSpring = this.lyricPlayer.getEnableSpring();
      if (immediate || !enableSpring) {
        this.lineTransforms.scale.setPosition(scale);
      } else {
        this.lineTransforms.scale.setTargetPosition(scale);
      }
    }
    update(delta = 0) {
      if (!this.lyricPlayer.getEnableSpring()) return;
      const scaleMoving = !this.lineTransforms.scale.arrived();
      this.lineTransforms.scale.update(delta);
      if (scaleMoving) {
        this.isUiDirty = true;
      }
    }
    commitChanges() {
      if (this.isUiDirty) {
        this.rebuildStyle();
        this.isUiDirty = false;
      }
    }
    /** @internal */
    _getDebugTargetPos() {
      return `[\u4F4D\u79FB: ${this.top}; \u7F29\u653E: ${this.scale}; \u5EF6\u65F6: ${this.delay}]`;
    }
    disposeElements() {
      this.balancer?.reset();
      for (const realWord of this.splittedWords) {
        for (const a of realWord.elementAnimations) {
          a.cancel();
        }
        for (const a of realWord.maskAnimations) {
          a.cancel();
        }
        for (const sub of realWord.subElements) {
          sub.remove();
          sub.parentNode?.removeChild(sub);
        }
        realWord.elementAnimations = [];
        realWord.maskAnimations = [];
        realWord.subElements = [];
        if (realWord.mainElement?.parentNode) {
          realWord.mainElement.parentNode.removeChild(realWord.mainElement);
        }
      }
      this.splittedWords = [];
      const main = this.element.children[0];
      const trans = this.element.children[1];
      const roman = this.element.children[2];
      if (main) main.innerHTML = "";
      if (trans) trans.innerHTML = "";
      if (roman) roman.innerHTML = "";
    }
    dispose() {
      this.disposeElements();
      this.lyricPlayer.resizeObserver.unobserve(this.element);
      this.element.remove();
    }
  };

  // ../../../../../../../Code/applemusic-like-lyrics/packages/core/src/lyric-player/dom/index.ts
  var LyricLineMouseEvent = class extends MouseEvent {
    constructor(lineIndex, line, bgLine, event) {
      super(`line-${event.type}`, event);
      this.lineIndex = lineIndex;
      this.line = line;
      this.bgLine = bgLine;
    }
    lineIndex;
    line;
    bgLine;
    /**
     * 自定义标志位，用于记录外部是否调用了 `stopPropagation`
     */
    isPropagationStopped = false;
    stopPropagation() {
      this.isPropagationStopped = true;
      super.stopPropagation();
    }
    stopImmediatePropagation() {
      this.isPropagationStopped = true;
      super.stopImmediatePropagation();
    }
  };
  var DomLyricPlayer = class extends LyricPlayerBase {
    abortController = new AbortController();
    currentLyricGroups = [];
    onResize() {
      const computedStyles = getComputedStyle(this.element);
      this._baseFontSize = Number.parseFloat(computedStyles.fontSize);
      this.rebuildStyle();
    }
    supportPlusLighter = CSS.supports(
      "mix-blend-mode",
      "plus-lighter"
    );
    supportMaskImage = CSS.supports("mask-image", "none");
    innerSize = [0, 0];
    onMouseEventHandler = (e) => {
      const target = e.target;
      if (!(target instanceof Element)) return;
      const groupEl = target.closest(`.${lyric_player_default.lyricLineWrapper}`);
      if (!groupEl) return;
      const group = this.lyricGroupElementMap.get(groupEl);
      if (!group) return;
      const mainLine = group.mainLine;
      const bgLine = group.bgLine;
      const lineIndex = this.lyricLinesIndexes.get(mainLine) ?? -1;
      const evt = new LyricLineMouseEvent(lineIndex, mainLine, bgLine, e);
      const isDispatched = this.dispatchEvent(evt);
      if (!isDispatched || evt.defaultPrevented) {
        e.preventDefault();
      }
      if (evt.isPropagationStopped) {
        e.stopPropagation();
        e.stopImmediatePropagation();
      }
    };
    /**
     * 是否为非逐词歌词
     * @internal
     */
    _getIsNonDynamic() {
      return this.isNonDynamic;
    }
    _baseFontSize = Number.parseFloat(
      getComputedStyle(this.element).fontSize
    );
    get baseFontSize() {
      return this._baseFontSize;
    }
    constructor() {
      super();
      this.onResize();
      this.element.classList.add("amll-lyric-player", "dom");
      if (this.disableSpring) {
        this.element.classList.add(lyric_player_default.disableSpring);
      }
      this.element.addEventListener("click", this.onMouseEventHandler, {
        signal: this.abortController.signal
      });
      this.element.addEventListener("contextmenu", this.onMouseEventHandler, {
        signal: this.abortController.signal
      });
    }
    rebuildStyle() {
    }
    setWordFadeWidth(value = 0.5) {
      super.setWordFadeWidth(value);
      for (const group of this.currentLyricGroups) {
        group.mainLine.updateMaskImageSync();
        group.bgLine?.updateMaskImageSync();
      }
    }
    /**
     * 重新构建歌词行和时间状态
     *
     * 一般用于在调用 {@link setLyricProcessConfig} 更新配置后手动刷新视图，
     * 或在外部样式/DOM 结构发生改变后重置歌词视图
     *
     * @param initialTime 重建后对齐的初始时间（毫秒），默认使用当前播放进度
     */
    buildLyricGroups() {
      if (this.hasDuetLine) {
        this.element.classList.add(lyric_player_default.hasDuetLine);
      } else {
        this.element.classList.remove(lyric_player_default.hasDuetLine);
      }
      let currentGroup = null;
      for (let i = 0; i < this.processedLines.length; i++) {
        const line = this.processedLines[i];
        const lineEl = new LyricLineEl(this, line);
        this.lyricLinesIndexes.set(lineEl, i);
        if (!line.isBG || !currentGroup) {
          currentGroup = new LyricLineGroup(this, lineEl);
          this.currentLyricGroups.push(currentGroup);
          this.lyricGroupElementMap.set(currentGroup.element, currentGroup);
        } else {
          currentGroup.addBgLine(lineEl);
        }
      }
    }
    rebuildLyricView(initialTime = this.getCurrentTime()) {
      super.rebuildLyricView(initialTime);
      this.setLinePosXSpringParams({});
      this.setLinePosYSpringParams({});
      this.setLineScaleSpringParams({});
      this.update(0);
    }
    pause() {
      super.pause();
      this.element.classList.remove(lyric_player_default.playing);
      this.interludeDots.pause();
      for (const group of this.currentLyricGroups) {
        group.mainLine.pause();
        group.bgLine?.pause();
      }
    }
    resume() {
      super.resume();
      this.element.classList.add(lyric_player_default.playing);
      this.interludeDots.resume();
      for (const group of this.currentLyricGroups) {
        group.mainLine.resume();
        group.bgLine?.resume();
      }
    }
    update(delta = 0) {
      super.update(delta);
      if (!this.supportMaskImage) {
        this.element.style.setProperty(
          "--amll-player-time",
          `${this.getCurrentTime()}`
        );
      }
      if (!this.isPageVisible) return;
      const deltaS = delta / 1e3;
      for (const group of this.currentLyricGroups) {
        group.update(deltaS);
      }
      for (const group of this.currentLyricGroups) {
        group.commitChanges();
      }
    }
    dispose() {
      super.dispose();
      this.abortController.abort();
      this.element.remove();
      for (const group of this.currentLyricGroups) {
        group.dispose();
      }
      this.bottomLine.dispose();
      this.interludeDots.dispose();
    }
  };

  // strip.ts
  var IslandLyricPlayer = class extends DomLyricPlayer {
    placing = false;
    trackID = "";
    entrance;
    focalRow;
    get visibleContent() {
      const target = this.layoutState.alignTarget;
      if (target.type !== "line") return target.type;
      const line = this.currentLyricGroups[target.index]?.mainLine.getLine();
      if (!line) return "";
      return JSON.stringify([
        line.words.map((w) => w.word).join("").replace(/\s+/g, " ").trim(),
        line.translatedLyric,
        line.words.flatMap((w) => w.ruby ?? []).map((part) => part.word).join("")
      ]);
    }
    dispose() {
      this.resizeObserver.disconnect();
      super.dispose();
    }
    getEnableSpring() {
      return !this.placing && super.getEnableSpring();
    }
    calcLayout(reason) {
      super.calcLayout(reason);
      const target = this.layoutState.alignTarget;
      const next = target.type === "line" ? this.currentLyricGroups[target.index]?.element : void 0;
      if (this.focalRow !== next) {
        this.focalRow?.classList.remove("strip-current");
        next?.classList.add("strip-current");
        this.focalRow = next;
      }
      if (reason === "resize") this.finishPlacement();
    }
    finishPlacement() {
      if (!this.placing || !this.size[0] || !this.size[1]) return;
      this.update(0);
      const target = this.layoutState.alignTarget;
      if (target.type === "line") {
        const group = this.currentLyricGroups[target.index];
        if (!group || !this.lyricGroupSize.get(group)?.[1]) return;
      } else if (target.type === "interlude" && !this.layoutState.interludeDotsSize[1]) {
        return;
      }
      if (target.type === "interlude" && !this.getIsPlaying()) {
        this.interludeDots.resume();
        this.interludeDots.update(0);
        this.interludeDots.pause();
      }
      followLongLine(position(state));
      this.placing = false;
      const root = this.getElement();
      root.style.visibility = "visible";
      const old = previousLayer;
      previousLayer = void 0;
      if (!old) return;
      if (state.visible && this.trackID !== old.trackID && this.visibleContent !== old.visibleContent) {
        retire(old);
        this.entrance = root.animate([{ opacity: 0 }, { opacity: 1 }], fadeOptions());
      } else {
        if (old.entrance?.playState === "running" && old.entrance.effect instanceof KeyframeEffect) {
          old.entrance.effect.target = root;
          this.entrance = old.entrance;
        }
        old.dispose();
      }
    }
  };
  var stage = document.getElementById("stage");
  function makePlayer() {
    const instance = new IslandLyricPlayer();
    instance.setEnableBlur(true);
    instance.setEnableSpring(true);
    instance.setWordFadeWidth(0.6);
    instance.setAlignPosition(0.5);
    instance.pause();
    stage.prepend(instance.getElement());
    return instance;
  }
  var player = makePlayer();
  var previousLayer;
  function releasePrevious() {
    if (previousLayer) retire(previousLayer);
    previousLayer = void 0;
  }
  var state = { trackID: "", anchor: 0, elapsed: 0, playing: false, visible: false, loading: false, fadeMS: 340 };
  var rows = [];
  var active = false;
  var frame = 0;
  var previous = 0;
  var position = (s) => Math.max(0, s.elapsed + (s.playing ? Date.now() - s.anchor : 0));
  function fadeOptions() {
    return { duration: state.fadeMS, easing: "cubic-bezier(.333,.06,.667,1)" };
  }
  function retire(instance) {
    const root = instance.getElement();
    instance.placing = false;
    if (!state.visible || getComputedStyle(root).visibility === "hidden") {
      instance.dispose();
      return;
    }
    root.setAttribute("aria-hidden", "true");
    const opacity = getComputedStyle(root).opacity;
    const fade = root.animate([{ opacity }, { opacity: 0 }], { ...fadeOptions(), fill: "forwards" });
    fade.finished.then(() => instance.dispose(), () => instance.dispose());
  }
  var scroll;
  function followLongLine(ms, syncClock = false) {
    if (scroll && ms >= scroll.row.startTime && ms < scroll.nextStart && scroll.hasContent()) {
      if (syncClock) scroll.sync(ms, active);
      else scroll.updateEdges(ms);
      return;
    }
    scroll?.dispose();
    scroll = void 0;
    let lo = 0, hi = rows.length;
    while (lo < hi) {
      const mid = lo + hi >>> 1;
      if (rows[mid].startTime <= ms) lo = mid + 1;
      else hi = mid;
    }
    const index = lo - 1;
    const row = rows[index];
    const main = row && player.currentLyricGroups[index]?.element.querySelector("." + lyric_player_default.lyricMainLine);
    if (!main) return;
    const onlyWord = row.words.length === 1 ? row.words[0] : void 0;
    if (onlyWord?.ruby?.length && main.childNodes.length === 1 && main.firstChild?.nodeType === Node.TEXT_NODE) {
      const ruby = document.createElement("ruby");
      const reading = document.createElement("rt");
      reading.textContent = onlyWord.ruby.map((part) => part.word).join("");
      ruby.append(onlyWord.word, reading);
      main.replaceChildren(ruby);
    }
    if (!main.firstChild || !row.words.length) return;
    scroll = new HorizontalScroll(
      main,
      row,
      rows[index + 1]?.startTime ?? Infinity,
      () => ({ ms: position(state), running: active })
    );
  }
  function tick(now) {
    const ms = position(state);
    player.setCurrentTime(ms);
    player.update(previous ? Math.min(100, now - previous) : 0);
    followLongLine(ms);
    previous = now;
    frame = requestAnimationFrame(tick);
  }
  function sync(next, lines) {
    const ms = position(next);
    const seek = Math.abs(position(state) - ms) > 420 || next.visible !== state.visible;
    state = next;
    if (lines) {
      if (rows.length) {
        cancelAnimationFrame(frame);
        active = false;
        if ((lines.length || next.loading) && next.visible && player.getElement().style.visibility === "visible") {
          releasePrevious();
          previousLayer = player;
          for (const animation of player.getElement().getAnimations({ subtree: true })) {
            if (animation.effect instanceof KeyframeEffect && animation.effect.target !== player.getElement()) animation.pause();
          }
        } else {
          retire(player);
        }
        player = makePlayer();
      }
      player.getElement().style.visibility = "hidden";
      player.placing = lines.length > 0;
      player.trackID = next.trackID;
      scroll?.dispose();
      scroll = void 0;
      rows = lines.map((line) => ({
        ...line,
        words: line.words.map((word) => ({ ...word, word: word.word.replace(/[\r\n\u000B\f\u0085\u2028\u2029]+/g, " ") }))
      }));
      player.getElement().classList.toggle("has-translation", rows.some((row) => row.translatedLyric));
      player.getElement().classList.toggle("has-readings", rows.some((row) => row.words.some((word) => word.ruby?.length)));
      player.setLyricLines(rows.map((l) => ({ ...l, isBG: false, isDuet: false, translatedLyric: l.translatedLyric ?? "", romanLyric: "" })), ms);
    }
    if (!next.visible || !rows.length && !next.loading) releasePrevious();
    player.setCurrentTime(ms, seek);
    const run = next.visible && next.playing && rows.length > 0;
    if (run !== active) {
      active = run;
      if (run) {
        player.resume();
        previous = 0;
        frame = requestAnimationFrame(tick);
      } else {
        cancelAnimationFrame(frame);
        player.pause();
      }
    }
    if (!run || seek) player.update(0);
    followLongLine(ms, true);
    if (lines) player.finishPlacement();
  }
  matchMedia("(prefers-reduced-motion: reduce)").addEventListener("change", () => scroll?.layout(true));
  Object.assign(window, { islandLyrics: { sync } });
})();
