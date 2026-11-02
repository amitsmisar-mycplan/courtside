#!/usr/bin/env python3 -I
"""Turn a CorpusStressTests JSON report into Markdown tables for docs/testing/.

Usage: scripts/corpus-report.py <report.json>   (prints Markdown; text only, no media)
"""
import json
import sys


def mmss(seconds):
    seconds = int(round(seconds))
    return f"{seconds // 60}:{seconds % 60:02d}"


def main(path):
    with open(path) as handle:
        report = json.load(handle)
    videos = report["videos"]
    out = []
    out.append(
        f"Seed {report['seed']}, {report['marksPerGame']} planned marks per game (+5 for the undo check, 3 undone), "
        f"trim / vertical / delete on {report.get('trimmedClipsPerGame', 3)} clip(s) per game, "
        f"clip window {report['preRoll']:g} s before / {report['postRoll']:g} s after. "
        "Timings are from the Simulator, which encodes video in software; a device's hardware encoder is much faster, "
        "so these times say nothing about speed on a phone. "
        f"Peak memory over the whole run: {report.get('peakMemoryMB', 0):.0f} MB."
    )
    out.append("")
    for video in videos:
        clips = video["clipSeconds"]
        checks = video["markChecks"]
        out.append(f"### {video['file']}")
        out.append("")
        out.append("| Step | Result |")
        out.append("|---|---|")
        out.append(f"| Source | {mmss(video['sourceDuration'])}, shown {video['sourceShown']}, nominal {video['sourceNominalFPS']:.2f} fps |")
        out.append(f"| Import | {video['importSeconds']:.1f} s, {video['importProgressReports']} progress updates, ends at 100 %; game dated {video.get('importedCreatedAt') or 'now'} |")
        out.append(
            f"| Marks | {video['marksPlaced']} of {video['plannedMarks']} placed by the tap code in {video['markSeconds']:.0f} s; "
            f"{checks['inFirst10s']} in the first 10 s, {checks['inLast3s']} in the last 3 s, "
            f"{checks['pairsUnder13s']} neighbours < 13 s apart, {checks['pairsUnder1s']} < 1 s apart; 2 s tap guard held |"
        )
        out.append(f"| Undo (5 taps, 3 undos) | {'correct 2 kept' if video['undoOK'] else 'WRONG'} |")
        if clips:
            out.append(
                f"| Extract | {video['clipsMade']} clips ({video['clipsFailed']} failed) in {mmss(video['extractSeconds'])}; "
                f"per clip median {sorted(clips)[len(clips) // 2]:.1f} s, longest {max(clips):.1f} s |"
            )
        out.append(
            f"| Clip checks | {video['clipsChecked']} checked (file, window, duration ±0.15 s, video+audio, shape, thumbnail); "
            f"largest duration error {video['maxDurationError'] * 1000:.0f} ms |"
        )
        for slow in video["slowMo"]:
            speeds = ", ".join(slow["offered"]) or "none"
            out.append(f"| Slow mo, {slow['clip']} | real {slow['realFPS']:.2f} fps, app reads {slow['appFPS']:.2f}; offered: {speeds} |")
        for op in video["operations"]:
            out.append(f"| Trim + vertical + delete, {op['clip']} | trim {op['detail']} in {op['seconds']:.1f} s; vertical export {op['verticalSeconds']:.1f} s; deleted |")
        out.append(f"| Orphans after deletes | {len(video['orphans']) or 'none'} |")
        out.append(f"| Disk | {video['diskAfterImportMB']:.0f} MB after import, peak {video['diskPeakMB']:.0f} MB; all removed at the end |")
        out.append(f"| Peak memory | {video['peakMemoryMB']:.0f} MB |")
        out.append(f"| Failures | {len(video['failures'])} |")
        out.append("")

    out.append("### Totals")
    out.append("")
    total_clips = sum(v["clipsMade"] for v in videos)
    total_extract = sum(v["extractSeconds"] for v in videos)
    all_clips = [s for v in videos for s in v["clipSeconds"]]
    out.append("| | |")
    out.append("|---|---|")
    out.append(f"| Videos | {len(videos)} ({mmss(sum(v['sourceDuration'] for v in videos))} of footage) |")
    out.append(f"| Import | {sum(v['importSeconds'] for v in videos):.0f} s in total |")
    out.append(f"| Clips | {total_clips} made, {sum(v['clipsFailed'] for v in videos)} failed, {sum(v['clipsChecked'] for v in videos)} checked |")
    if all_clips:
        out.append(f"| Clip time | {mmss(total_extract)} in total; median {sorted(all_clips)[len(all_clips) // 2]:.1f} s per clip |")
    out.append(f"| Failures | {sum(len(v['failures']) for v in videos)} |")
    out.append("")

    failures = [(v["file"], f["step"], f["message"]) for v in videos for f in v["failures"]]
    out.append("### Failures")
    out.append("")
    if failures:
        out.append("| File | Step | What |")
        out.append("|---|---|---|")
        for file, step, message in failures:
            out.append(f"| {file} | {step} | {message} |")
    else:
        out.append("None.")
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1])
