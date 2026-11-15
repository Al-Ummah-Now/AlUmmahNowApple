#if os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import AppKit
    import SwiftUI

    /// Pure geometry for the timeline, so hit-testing and drags are unit-tested.
    struct TimelineGeometry {
        let pointsPerSecond: CGFloat

        func x(_ ms: Int) -> CGFloat { CGFloat(ms) / 1000 * pointsPerSecond }
        func ms(_ x: CGFloat) -> Int { max(0, Int((x / pointsPerSecond * 1000).rounded())) }

        /// Ruler tick spacing in seconds for the zoom level: labels at least ~60 pt apart.
        func tickSeconds() -> Int {
            [1, 2, 5, 10, 15, 30, 60, 120, 300].first { CGFloat($0) * pointsPerSecond >= 60 } ?? 600
        }

        /// A trim of `clip` by a timeline drag of `deltaMs`: the new source range, kept inside the file and at least
        /// 100 ms long.
        static func trimmed(
            _ clip: FlattenedTimeline.Clip, start: Bool, deltaMs: Int, sourceDurationMs: Int
        ) -> (inMs: Int, outMs: Int) {
            let sourceDelta = Int((Double(deltaMs) * clip.speed).rounded())
            if start {
                return (min(max(0, clip.inMs + sourceDelta), clip.outMs - 100), clip.outMs)
            }
            return (clip.inMs, max(clip.inMs + 100, min(sourceDurationMs, clip.outMs + sourceDelta)))
        }
    }

    extension TimelineGeometry {
        /// A title after a drag of `deltaMs`: moved, or one edge moved with the other kept and at least
        /// `EditorModel.minTitleMs` long.
        static func retimed(
            _ title: FlattenedTimeline.Title, kind: TimelineStrip.DragKind, deltaMs: Int
        ) -> (startMs: Int, durationMs: Int) {
            switch kind {
            case .move:
                return (max(0, title.startMs + deltaMs), title.durationMs)
            case .trimStart:
                let start = min(max(0, title.startMs + deltaMs), title.endMs - EditorModel.minTitleMs)
                return (start, title.endMs - start)
            case .trimEnd:
                return (title.startMs, max(EditorModel.minTitleMs, title.durationMs + deltaMs))
            }
        }
    }

    /// The timeline: a ruler, the titles lane, one row per track, the clips and the playhead. Time runs left to right in every
    /// language, like the editors creators already use.
    struct TimelineStrip: View {
        @Environment(\.l10n) private var l10n
        let model: EditorModel
        let pointsPerSecond: CGFloat
        let clock: EditorClock
        let onScrub: (Int) -> Void
        var onEditTitle: (String) -> Void = { _ in }

        enum DragKind { case move, trimStart, trimEnd }
        @State private var drag: (clipID: String, kind: DragKind, deltaMs: Int)?

        private var geometry: TimelineGeometry { TimelineGeometry(pointsPerSecond: pointsPerSecond) }
        private let rulerHeight: CGFloat = 24
        private let rowHeight: CGFloat = 72
        private let laneHeight: CGFloat = 40

        var body: some View {
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    let width = max(proxy.size.width, geometry.x(model.timeline.durationMs + 10_000))
                    VStack(alignment: .leading, spacing: FanousScale.spacingXs) {
                        ruler(width: width)
                        titleLane(width: width)
                        ForEach(tracks) { track in row(track, width: width) }
                    }
                    .frame(width: width, alignment: .leading)
                    .overlay(alignment: .topLeading) { playhead }
                }
            }
            .padding(FanousScale.spacingSm)
            .background(Fanous.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Fanous.outline, lineWidth: 1))
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor-timeline")
        }

        /// The video track even when empty, so the timeline always shows where clips go.
        private var tracks: [FlattenedTimeline.Track] {
            model.timeline.tracks.isEmpty
                ? [FlattenedTimeline.Track(id: EditorModel.videoTrack, kind: "video", clips: [])]
                : model.timeline.tracks
        }

        private func ruler(width: CGFloat) -> some View {
            let step = geometry.tickSeconds()
            let count = Int(width / (CGFloat(step) * pointsPerSecond)) + 1
            return ZStack(alignment: .topLeading) {
                Rectangle().fill(Fanous.surfaceRaised)
                ForEach(0..<count, id: \.self) { index in
                    let x = geometry.x(index * step * 1000)
                    VStack(alignment: .leading, spacing: 2) {
                        Rectangle().fill(Fanous.outline).frame(width: 1, height: 8)
                        Text(clock(index * step * 1000)).fanousFont(.caption).foregroundStyle(Fanous.textMuted)
                            .monospacedDigit().fixedSize()
                    }
                    .offset(x: x)
                }
            }
            .frame(width: width, height: rulerHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { onScrub(geometry.ms($0.location.x)) })
            .accessibilityElement()
            .accessibilityLabel(l10n("studio.editor.playhead"))
            .accessibilityValue(clock(model.playheadMs))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 1_000 : -1_000
                onScrub(min(model.timeline.durationMs, max(0, model.playheadMs + step)))
            }
            .accessibilityIdentifier("editor-ruler")
        }

        private func row(_ track: FlattenedTimeline.Track, width: CGFloat) -> some View {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Fanous.background)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded {
                            model.selection = nil
                            onScrub(geometry.ms($0.location.x))
                        })
                if track.clips.isEmpty {
                    Label(l10n("studio.editor.track.video"), systemImage: "film").fanousFont(.caption)
                        .foregroundStyle(Fanous.textMuted).padding(FanousScale.spacingSm)
                }
                ForEach(Array(track.clips.enumerated()), id: \.element.clipID) { index, clip in
                    clipBlock(clip, index: index)
                }
            }
            .frame(width: width, height: rowHeight, alignment: .topLeading)
        }

        private func clipBlock(_ clip: FlattenedTimeline.Clip, index: Int) -> some View {
            let selected = model.selection == clip.clipID
            let frame = previewFrame(clip)
            let name = model.sourceNames[clip.sourceID] ?? clip.sourceID
            return VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(selected ? Fanous.onPrimary : Fanous.accent).frame(height: 4).opacity(0.9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).fanousFont(.label).lineLimit(1)
                    Text(clock(frame.durationMs)).fanousFont(.caption).monospacedDigit().opacity(0.8)
                }
                .foregroundStyle(selected ? Fanous.onPrimary : Fanous.textPrimary)
                .padding(.horizontal, FanousScale.spacingSm)
                .padding(.vertical, FanousScale.spacingXs)
                Spacer(minLength: 0)
            }
            .frame(width: max(8, geometry.x(frame.durationMs) - 2), height: rowHeight - 8, alignment: .topLeading)
            .background(selected ? AnyShapeStyle(Fanous.primary) : AnyShapeStyle(Fanous.surfaceRaised))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        selected ? AnyShapeStyle(Fanous.focusRing) : AnyShapeStyle(Fanous.outline),
                        lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .leading) { trimHandle(clip, start: true) }
            .overlay(alignment: .trailing) { trimHandle(clip, start: false) }
            .offset(x: geometry.x(frame.startMs) + 1, y: 4)
            .onTapGesture { model.selection = clip.clipID }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        model.selection = clip.clipID
                        drag = (clip.clipID, .move, signedMs(value.translation.width))
                    }
                    .onEnded { _ in
                        if let drag, drag.clipID == clip.clipID {
                            model.move(clip.clipID, toMs: clip.timelineStartMs + drag.deltaMs)
                        }
                        drag = nil
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                l10n(
                    "studio.editor.clip.label", (index + 1).formatted(.number.locale(l10n.language.locale)), name,
                    clock(clip.timelineStartMs), clock(clip.timelineDurationMs))
            )
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.selection = clip.clipID }
            .accessibilityAction(named: l10n("studio.editor.earlier")) { model.nudge(clip.clipID, by: -EditorModel.nudgeMs) }
            .accessibilityAction(named: l10n("studio.editor.later")) { model.nudge(clip.clipID, by: EditorModel.nudgeMs) }
            .accessibilityIdentifier("clip-\(index)")
        }

        /// A horizontal drag distance as signed milliseconds.
        private func signedMs(_ width: CGFloat) -> Int { geometry.ms(abs(width)) * (width < 0 ? -1 : 1) }

        /// Where the clip is drawn while it is being dragged or trimmed.
        private func previewFrame(_ clip: FlattenedTimeline.Clip) -> (startMs: Int, durationMs: Int) {
            guard let drag, drag.clipID == clip.clipID else { return (clip.timelineStartMs, clip.timelineDurationMs) }
            switch drag.kind {
            case .move:
                return (max(0, clip.timelineStartMs + drag.deltaMs), clip.timelineDurationMs)
            case .trimStart, .trimEnd:
                let start = drag.kind == .trimStart
                let range = trimmedRange(clip, start: start, deltaMs: drag.deltaMs)
                let duration = Int((Double(range.outMs - range.inMs) / max(clip.speed, 0.01)).rounded())
                let shift = start ? clip.timelineDurationMs - duration : 0
                return (clip.timelineStartMs + shift, duration)
            }
        }

        private func trimmedRange(_ clip: FlattenedTimeline.Clip, start: Bool, deltaMs: Int) -> (inMs: Int, outMs: Int) {
            TimelineGeometry.trimmed(
                clip, start: start, deltaMs: deltaMs, sourceDurationMs: model.sourceDurations[clip.sourceID] ?? clip.outMs)
        }

        private func trimHandle(_ clip: FlattenedTimeline.Clip, start: Bool) -> some View {
            Rectangle()
                .fill(Fanous.focusRing.opacity(model.selection == clip.clipID ? 0.9 : 0.001))
                .frame(width: 6)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            model.selection = clip.clipID
                            drag = (clip.clipID, start ? .trimStart : .trimEnd, signedMs(value.translation.width))
                        }
                        .onEnded { _ in
                            if let drag, drag.clipID == clip.clipID {
                                let range = trimmedRange(clip, start: start, deltaMs: drag.deltaMs)
                                model.trim(clip.clipID, inMs: range.inMs, outMs: range.outMs)
                            }
                            drag = nil
                        }
                )
                .accessibilityHidden(true)
        }

        // MARK: Titles

        /// The titles lane above the video: one block per title, dragged to move, edges dragged to retime,
        /// double-clicked to edit the text.
        private func titleLane(width: CGFloat) -> some View {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Fanous.background)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded {
                            model.selection = nil
                            onScrub(geometry.ms($0.location.x))
                        })
                if model.titles.isEmpty {
                    Label(l10n("studio.editor.track.titles"), systemImage: "textformat").fanousFont(.caption)
                        .foregroundStyle(Fanous.textMuted).padding(.horizontal, FanousScale.spacingSm)
                        .frame(height: laneHeight)
                }
                ForEach(Array(model.titles.enumerated()), id: \.element.titleID) { index, title in
                    titleBlock(title, index: index)
                }
            }
            .frame(width: width, height: laneHeight, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(l10n("studio.editor.track.titles"))
            .accessibilityIdentifier("editor-title-lane")
        }

        private func titleBlock(_ title: FlattenedTimeline.Title, index: Int) -> some View {
            let selected = model.selection == title.titleID
            let frame = titleFrame(title)
            let text = title.lines.first?.text ?? ""
            let kind = l10n(
                title.style.position == .lowerThird ? "studio.editor.titles.lowerThird" : "studio.editor.titles.title")
            return HStack(spacing: FanousScale.spacingXs) {
                Image(systemName: title.style.position == .lowerThird ? "rectangle.bottomthird.inset.filled" : "textformat")
                    .font(.system(size: 11)).accessibilityHidden(true)
                Text(text).fanousFont(.label).lineLimit(1)
                    .environment(
                        \.layoutDirection,
                        TitleRenderer.isRightToLeft(title.lines.first?.locale ?? "en") ? .rightToLeft : .leftToRight)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Fanous.onPrimary : Fanous.textPrimary)
            .padding(.horizontal, FanousScale.spacingSm)
            .frame(width: max(8, geometry.x(frame.durationMs) - 2), height: laneHeight - 8, alignment: .leading)
            .background(selected ? AnyShapeStyle(Fanous.primary) : AnyShapeStyle(Fanous.surfaceRaised))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        selected ? AnyShapeStyle(Fanous.focusRing) : AnyShapeStyle(Fanous.accent),
                        lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .leading) { titleHandle(title, start: true) }
            .overlay(alignment: .trailing) { titleHandle(title, start: false) }
            .offset(x: geometry.x(frame.startMs) + 1, y: 4)
            .onTapGesture(count: 2) {
                model.selection = title.titleID
                onEditTitle(title.titleID)
            }
            .onTapGesture { model.selection = title.titleID }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        model.selection = title.titleID
                        drag = (title.titleID, .move, signedMs(value.translation.width))
                    }
                    .onEnded { _ in
                        if let drag, drag.clipID == title.titleID {
                            model.moveTitle(title.titleID, toMs: title.startMs + drag.deltaMs)
                        }
                        drag = nil
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                l10n(
                    "studio.editor.titles.label", kind, (index + 1).formatted(.number.locale(l10n.language.locale)),
                    title.lines.map(\.text).joined(separator: " · "), clock(title.startMs), clock(title.durationMs))
            )
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.selection = title.titleID }
            .accessibilityAction(named: l10n("studio.editor.titles.editText")) {
                model.selection = title.titleID
                onEditTitle(title.titleID)
            }
            .accessibilityAction(named: l10n("studio.editor.earlier")) { model.nudge(title.titleID, by: -EditorModel.nudgeMs) }
            .accessibilityAction(named: l10n("studio.editor.later")) { model.nudge(title.titleID, by: EditorModel.nudgeMs) }
            .accessibilityAction(named: l10n("studio.editor.titles.shorter")) {
                model.resizeTitle(title.titleID, by: -EditorModel.nudgeMs / 2)
            }
            .accessibilityAction(named: l10n("studio.editor.titles.longer")) {
                model.resizeTitle(title.titleID, by: EditorModel.nudgeMs / 2)
            }
            .accessibilityIdentifier("title-\(index)")
        }

        /// Where a title is drawn while it is being dragged or retimed.
        private func titleFrame(_ title: FlattenedTimeline.Title) -> (startMs: Int, durationMs: Int) {
            guard let drag, drag.clipID == title.titleID else { return (title.startMs, title.durationMs) }
            return TimelineGeometry.retimed(title, kind: drag.kind, deltaMs: drag.deltaMs)
        }

        private func titleHandle(_ title: FlattenedTimeline.Title, start: Bool) -> some View {
            Rectangle()
                .fill(Fanous.focusRing.opacity(model.selection == title.titleID ? 0.9 : 0.001))
                .frame(width: 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            model.selection = title.titleID
                            drag = (title.titleID, start ? .trimStart : .trimEnd, signedMs(value.translation.width))
                        }
                        .onEnded { _ in
                            if let drag, drag.clipID == title.titleID {
                                let next = TimelineGeometry.retimed(title, kind: drag.kind, deltaMs: drag.deltaMs)
                                model.retimeTitle(title.titleID, startMs: next.startMs, durationMs: next.durationMs)
                            }
                            drag = nil
                        }
                )
                .accessibilityHidden(true)
        }

        private var playhead: some View {
            Rectangle().fill(Fanous.focusRing)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10)).foregroundStyle(Fanous.focusRing)
                        .offset(y: -2)
                }
                .offset(x: geometry.x(model.playheadMs) - 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
#endif
