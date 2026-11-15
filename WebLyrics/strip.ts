import { HorizontalScroll } from "./horizontal-scroll";
import { DomLyricPlayer } from "amll-engine";
import styles from "amll-styles";

// AMLL normally flies newly created groups in from outside the viewport.
class IslandLyricPlayer extends DomLyricPlayer {
    placing = false;
    trackID = "";
    entrance?: Animation;
    private focalRow?: HTMLElement;

    get visibleContent(): string {
        const target = this.layoutState.alignTarget;
        if (target.type !== "line") return target.type;
        const line = this.currentLyricGroups[target.index]?.mainLine.getLine();
        if (!line) return "";
        return JSON.stringify([
            line.words.map(w => w.word).join("").replace(/\s+/g," ").trim(),
            line.translatedLyric,
            line.words.flatMap(w => w.ruby ?? []).map(part => part.word).join("")
        ]);
    }

    override dispose() {
        this.resizeObserver.disconnect();
        super.dispose();
    }

    override getEnableSpring(): boolean {
        return !this.placing && super.getEnableSpring();
    }

    override calcLayout(reason: Parameters<DomLyricPlayer["calcLayout"]>[0]) {
        super.calcLayout(reason);
        const target = this.layoutState.alignTarget;
        const next = target.type === "line" ? this.currentLyricGroups[target.index]?.element : undefined;
        if (this.focalRow !== next) {
            this.focalRow?.classList.remove("strip-current");
            next?.classList.add("strip-current");
            this.focalRow = next;
        }
        if (reason === "resize") this.finishPlacement();
    }

    finishPlacement() {
        if (!this.placing || !this.size[0] || !this.size[1]) return;

        // AMLL delivers its measured group heights through ResizeObserver before paint.
        // Commit that layout even if playback is paused and no animation loop is running.
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
        previousLayer = undefined;
        if (!old) return;
        if (state.visible && this.trackID !== old.trackID && this.visibleContent !== old.visibleContent) {
            retire(old);
            this.entrance = root.animate([{opacity:0}, {opacity:1}], fadeOptions());
        } else {
            // A timing upgrade can arrive midway through the original crossfade.
            // Move that same running animation onto the corrected, aligned layer.
            if (old.entrance?.playState === "running" && old.entrance.effect instanceof KeyframeEffect) {
                old.entrance.effect.target = root;
                this.entrance = old.entrance;
            }
            old.dispose();
        }
    }
}
const stage = document.getElementById("stage")!;
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
let player = makePlayer();
let previousLayer: IslandLyricPlayer | undefined;
function releasePrevious() {
    if (previousLayer) retire(previousLayer);
    previousLayer = undefined;
}

type Word = { word: string; startTime: number; endTime: number; ruby?: { word: string }[] };
type Line = { words: Word[]; startTime: number; endTime: number; translatedLyric?: string };
type State = { trackID: string; anchor: number; elapsed: number; playing: boolean; visible: boolean; loading: boolean; fadeMS: number };
let state: State = { trackID:"", anchor: 0, elapsed: 0, playing: false, visible: false, loading: false, fadeMS: 340 };
let rows: Line[] = [];
let active = false, frame = 0, previous = 0;
const position = (s: State) => Math.max(0, s.elapsed + (s.playing ? Date.now() - s.anchor : 0));

function fadeOptions(): KeyframeAnimationOptions {
    return {duration: state.fadeMS, easing: "cubic-bezier(.333,.06,.667,1)"};
}

function retire(instance: IslandLyricPlayer) {
    const root = instance.getElement();
    instance.placing = false;
    if (!state.visible || getComputedStyle(root).visibility === "hidden") {
        instance.dispose();
        return;
    }
    root.setAttribute("aria-hidden", "true");
    const opacity = getComputedStyle(root).opacity;
    const fade = root.animate([{opacity}, {opacity:0}], {...fadeOptions(), fill:"forwards"});
    fade.finished.then(() => instance.dispose(), () => instance.dispose());
}

let scroll: HorizontalScroll | undefined;
function followLongLine(ms: number, syncClock = false) {
    if (scroll && ms >= scroll.row.startTime && ms < scroll.nextStart && scroll.hasContent()) {
        if (syncClock) scroll.sync(ms, active);
        else scroll.updateEdges(ms);
        return;
    }
    scroll?.dispose();
    scroll = undefined;
    let lo = 0, hi = rows.length;
    while (lo < hi) {
        const mid = (lo + hi) >>> 1;
        if (rows[mid].startTime <= ms) lo = mid + 1; else hi = mid;
    }
    const index = lo - 1;
    const row = rows[index];
    const main = row && player.currentLyricGroups[index]?.element.querySelector<HTMLElement>("." + styles.lyricMainLine);
    if (!main) return;
    // In a track containing only line timestamps AMLL emits a single text node.
    const onlyWord = row.words.length === 1 ? row.words[0] : undefined;
    if (onlyWord?.ruby?.length && main.childNodes.length === 1 && main.firstChild?.nodeType === Node.TEXT_NODE) {
        const ruby = document.createElement("ruby");
        const reading = document.createElement("rt");
        reading.textContent = onlyWord.ruby.map(part => part.word).join("");
        ruby.append(onlyWord.word, reading);
        main.replaceChildren(ruby);
    }
    if (!main.firstChild || !row.words.length) return;
    scroll = new HorizontalScroll(main, row, rows[index + 1]?.startTime ?? Infinity,
        () => ({ms:position(state), running:active}));
}
function tick(now: number) {
    const ms = position(state);
    player.setCurrentTime(ms);
    player.update(previous ? Math.min(100, now-previous) : 0);
    followLongLine(ms);
    previous = now;
    frame = requestAnimationFrame(tick);
}
function sync(next: State, lines?: Line[]) {
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
                for (const animation of player.getElement().getAnimations({subtree:true})) {
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
        scroll = undefined;
        rows = lines.map(line => ({
            ...line,
            words: line.words.map(word => ({...word, word: word.word.replace(/[\r\n\u000B\f\u0085\u2028\u2029]+/g, " ")}))
        }));
        player.getElement().classList.toggle("has-translation", rows.some(row => row.translatedLyric));
        player.getElement().classList.toggle("has-readings", rows.some(row => row.words.some(word => word.ruby?.length)));
        player.setLyricLines(rows.map(l => ({...l, isBG:false, isDuet:false, translatedLyric:l.translatedLyric ?? "", romanLyric:""})), ms);
    }
    if (!next.visible || (!rows.length && !next.loading)) releasePrevious();
    player.setCurrentTime(ms, seek);
    const run = next.visible && next.playing && rows.length > 0;
    if (run !== active) {
        active = run;
        if (run) { player.resume(); previous = 0; frame = requestAnimationFrame(tick); }
        else { cancelAnimationFrame(frame); player.pause(); }
    }
    if (!run || seek) player.update(0);
    followLongLine(ms, true);
    if (lines) player.finishPlacement();
}
matchMedia("(prefers-reduced-motion: reduce)").addEventListener("change", () => scroll?.layout(true));
Object.assign(window, { islandLyrics: { sync } });
