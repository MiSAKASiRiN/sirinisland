type Word = { word: string; startTime: number; endTime: number };
type Row = { words: Word[]; startTime: number; endTime: number };
const measuring = document.createElement("canvas").getContext("2d")!;

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
// Mirrors IslandMotion.scrollProgress. A clock-based curve also works when seeking or paused.
const residualVelocity = 7 * Math.exp(-6);
function landingDistance(u: number) {
    return ((2 - (6*u + 2)*Math.exp(-6*u))/6 - residualVelocity*u) / (1 - residualVelocity);
}
const fullLanding = landingDistance(1);
function scrollProgress(t: number, durationMS: number) {
    if (t <= 0 || t >= 1 || reducedMotion.matches) return t;
    const edge = Math.min(0.22, 480 / Math.max(1, durationMS));
    const distance = 1 - 1.5*edge + edge*fullLanding;
    if (t < edge) {
        const u = t / edge;
        return edge * u*u*u * (1 - 0.5*u) / distance;
    }
    if (t <= 1 - edge) return (t - 0.5*edge) / distance;
    return (1 - 1.5*edge + edge*landingDistance((t - 1 + edge) / edge)) / distance;
}

type Lane = {
    text: HTMLElement;
    clip: HTMLElement;
    animation: Animation;
    leadingAt: number;
    trailingUntil: number;
    edges: number;
};

// WebKit interpolates these transform keyframes on the compositor, independently
// of the JS loop driving AMLL's vertical spring and karaoke highlights.
export class HorizontalScroll {
    private lanes: Lane[] = [];
    private readonly translation: HTMLElement;
    private readonly observer: ResizeObserver;
    private readonly duration: number;
    private readonly hold: number;
    private mainContent: ChildNode | null;
    private translatedText: HTMLElement | null;
    private widths: number[] = [0];

    constructor(readonly main: HTMLElement, readonly row: Row, readonly nextStart: number,
                private readonly clock: () => {ms: number; running: boolean}) {
        const last = row.words[row.words.length - 1];
        this.duration = Math.max(1, Math.min(last.endTime, row.endTime, nextStart) - row.startTime);
        this.hold = Math.min(300, this.duration * 0.1);
        this.mainContent = main.firstChild;
        this.translation = main.nextElementSibling as HTMLElement;
        this.translatedText = this.translation.firstElementChild as HTMLElement | null;
        if (!this.translatedText && this.translation.firstChild) {
            this.translatedText = document.createElement("span");
            this.translatedText.append(this.translation.firstChild);
            this.translation.append(this.translatedText);
        }
        measuring.font = getComputedStyle(main).font || "600 14px sans-serif";
        for (const w of row.words) this.widths.push(this.widths[this.widths.length - 1] + measuring.measureText(w.word).width);
        this.observer = new ResizeObserver(() => this.layout());
        this.observer.observe(main.parentElement!);
        this.observer.observe(main);
        if (this.translatedText) this.observer.observe(this.translatedText);
        this.layout();
    }

    hasContent() {
        return this.main.isConnected && this.main.firstChild === this.mainContent && this.translation.firstChild === this.translatedText;
    }

    private wordProgress(ms: number) {
        const words = this.row.words;
        let lo = 0, hi = words.length - 1;
        while (lo < hi) {
            const mid = (lo + hi) >>> 1;
            if (ms < words[mid].endTime) hi = mid; else lo = mid + 1;
        }
        const w = words[lo];
        const f = Math.min(1, Math.max(0, (ms-w.startTime)/Math.max(1,w.endTime-w.startTime)));
        return (this.widths[lo] + f*(this.widths[lo+1]-this.widths[lo])) / Math.max(1, this.widths[this.widths.length-1]);
    }

    private lineProgress(t: number) {
        return Math.min(1, Math.max(0, (t - this.hold) / Math.max(1, this.duration - 2*this.hold)));
    }

    private dimensions = "";
    layout(force = false) {
        const main = this.main, line = main.parentElement!;
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
            const limit = excess + 8; // Leave clearance for the last animated glyph.
            const radius = Math.min(82, this.duration * 0.06);
            this.add(main, line, excess, t => {
                const ms = t + this.row.startTime;
                // A short triangular window smooths abrupt velocity changes between
                // consecutive word marks without moving the highlights themselves.
                const head = (this.wordProgress(ms-radius) + 2*this.wordProgress(ms-radius/2)
                    + 3*this.wordProgress(ms) + 2*this.wordProgress(ms+radius/2) + this.wordProgress(ms+radius)) / 9;
                const finish = Math.max(0, (this.lineProgress(t)-0.8)/0.2);
                const target = Math.min(1, Math.max(0, (width*head-room*0.6)/limit, finish));
                return limit * scrollProgress(target, this.duration);
            });
        }
        if (subOverflow > 0 && this.translatedText) {
            this.add(this.translatedText, this.translation, subOverflow, t =>
                (subOverflow+8)*scrollProgress(this.lineProgress(t), this.duration-2*this.hold));
        }
        const {ms, running} = this.clock();
        this.sync(ms, running);
    }

    private add(text: HTMLElement, clip: HTMLElement, excess: number, offset: (t: number) => number) {
        // Sample the motion once per cue. Include both hold boundaries even on long cues.
        const steps = Math.max(2, Math.min(300, Math.ceil(this.duration / 25)));
        const times = new Set([0, this.hold, this.duration-this.hold, this.duration]);
        for (let i=1; i<steps; i++) times.add(this.duration*i/steps);
        // A long held last word can otherwise stretch the sampling grid across a
        // cluster of fast words at the start of the same cue.
        if (text === this.main && this.duration / steps > 25) {
            for (const w of this.row.words) {
                for (const time of [w.startTime, w.endTime]) {
                    const t = time - this.row.startTime;
                    if (t > 0 && t < this.duration) times.add(t);
                }
            }
        }
        let previousT = 0, previousX = 0, leadingAt = Infinity, trailingUntil = Infinity;
        const frames = Array.from(times).sort((a,b) => a-b).map(t => {
            const x = t === 0 ? 0 : offset(t);
            const crossing = (threshold: number) => previousT + (t-previousT)*(threshold-previousX)/(x-previousX);
            if (leadingAt === Infinity && x > 1) leadingAt = crossing(1);
            if (trailingUntil === Infinity && x >= excess-1)
                trailingUntil = previousX >= excess-1 ? previousT : crossing(excess-1);
            previousT = t;
            previousX = x;
            return { offset:t/this.duration, transform:`translate3d(${-x}px,0,0)` };
        });
        const animation = text.animate(frames, {duration:this.duration, fill:"both"});
        this.lanes.push({text, clip, animation, leadingAt, trailingUntil, edges:-1});
    }

    sync(ms: number, running: boolean) {
        const t = Math.min(this.duration, Math.max(0, ms-this.row.startTime));
        for (const {animation} of this.lanes) {
            if (running && t < this.duration) {
                const timeline = document.timeline.currentTime;
                if (animation.playState !== "running" || Math.abs(Number(animation.currentTime)-t) > 20) {
                    animation.play();
                    if (typeof timeline === "number") animation.startTime = timeline-t;
                    else animation.currentTime = t;
                }
            } else {
                animation.pause();
                animation.currentTime = t;
            }
        }
        this.updateEdges(ms);
    }

    updateEdges(ms: number) {
        const t = ms - this.row.startTime;
        for (const lane of this.lanes) {
            const mask = (t > lane.leadingAt ? 1 : 0) | (t < lane.trailingUntil ? 2 : 0);
            if (mask === lane.edges) continue;
            lane.edges = mask;
            lane.clip.classList.toggle("fade-leading", !!(mask & 1));
            lane.clip.classList.toggle("fade-trailing", !!(mask & 2));
        }
    }

    private clear() {
        for (const lane of this.lanes) lane.animation.cancel();
        this.lanes = [];
        this.main.style.transform = "";
        if (this.translatedText) this.translatedText.style.transform = "";
        this.main.parentElement?.classList.remove("fade-leading","fade-trailing");
        this.translation.classList.remove("fade-leading","fade-trailing");
    }

    dispose() {
        this.observer.disconnect();
        for (const {animation,text} of this.lanes) {
            // The outgoing line can remain visible during AMLL's vertical spring or crossfade.
            if (text.isConnected) text.style.transform = getComputedStyle(text).transform;
            animation.cancel();
        }
        this.lanes = [];
    }
}
