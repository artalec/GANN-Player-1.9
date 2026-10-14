import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Список треков плейлиста: выделение, drag-n-drop файлов, перетаскивание порядка.
struct TrackList: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if let playlist = model.selectedPlaylist {
                if playlist.tracks.isEmpty {
                    emptyState
                } else {
                    trackListView(playlist)
                }
            } else {
                VStack {
                    Text("Плейлист не выбран")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Приём аудиофайлов, перетащенных из Finder
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
        .sheet(item: groupBinding($model.renamingGroupID)) { group in
            GroupRenameSheet(group: group) { newName in
                model.renameGroup(id: group.id, to: newName)
            }
        }
        .sheet(item: groupBinding($model.hotkeyGroupID)) { group in
            GroupHotkeySheet(group: group) { hotkey in
                model.setGroupHotkey(hotkey, for: group.id)
            }
        }
    }

    /// Привязка группы по её ID для листов: sheet(item:) требует Identifiable.
    private func groupBinding(_ source: Binding<UUID?>) -> Binding<TrackGroup?> {
        Binding<TrackGroup?>(
            get: { source.wrappedValue.flatMap { model.group(withID: $0) } },
            set: { newValue in source.wrappedValue = newValue?.id }
        )
    }

    // MARK: - Панель над списком

    private var topBar: some View {
        HStack(spacing: 10) {
            if let playlist = model.selectedPlaylist {
                RoundedRectangle(cornerRadius: 3)
                    .fill(playlist.color.swiftUIColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name).font(.headline)
                    Text("Треков: \(playlist.tracks.count)  ·  Длительность: \(playlistDuration(playlist))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if model.selection.count > 0 {
                Text("\(model.selection.count) выделено")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    model.removeSelectedTracks()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Удалить выделенные")
            }

            Text("клик · ⌘+клик · ⇧+клик для диапазона")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Button {
                model.createGroupFromSelection()
            } label: {
                Image(systemName: "rectangle.stack.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Объединить выделенные треки в группу")
            .disabled(model.selection.isEmpty)

            Button {
                model.playFirstTrackOfSelectedPlaylist()
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Запустить первый трек")
            .disabled(model.selectedPlaylist?.tracks.isEmpty ?? true)

            Button {
                addTracks()
            } label: {
                Label("Добавить", systemImage: "plus")
            }
            .disabled(model.selectedPlaylist == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Список

    /// Строки списка, которые видны сейчас. Треки свёрнутой группы скрыты,
    /// сама группа остаётся на месте.
    private func visibleRows(_ playlist: Playlist) -> [PlaylistOrderItem] {
        let collapsed = Set(playlist.groups.filter { !$0.isExpanded }.map(\.id))
        return playlist.rowOrder.filter { item in
            guard let trackID = item.trackID else { return true }
            guard let track = playlist.tracks.first(where: { $0.id == trackID }) else { return false }
            guard let groupID = track.groupID else { return true }
            return !collapsed.contains(groupID)
        }
    }

    private func trackListView(_ playlist: Playlist) -> some View {
        // Список без привязки выделения: строки групп не должны попадать в
        // выделение треков. Клик по строке обрабатывается самой строкой.
        List {
            ForEach(visibleRows(playlist)) { item in
                switch item {
                case .track(let trackID):
                    if let track = playlist.tracks.first(where: { $0.id == trackID }) {
                        trackRow(track, playlist: playlist, rowID: item.id)
                    }

                case .group(let groupID):
                    if let group = playlist.groups.first(where: { $0.id == groupID }) {
                        GroupRow(
                            group: group,
                            trackCount: playlist.tracks.filter { $0.groupID == group.id }.count,
                            isPlaying: isGroupPlaying(group, playlist: playlist),
                            isHoveredDropTarget: model.groupDropTargetID == group.id,
                            onToggleExpand: { model.toggleGroupExpanded(group.id) },
                            onPlay: { model.playGroup(id: group.id) },
                            onPause: {
                                if model.audioEngine.isPlaying {
                                    model.audioEngine.pause()
                                } else {
                                    model.audioEngine.resume()
                                }
                            },
                            onStop: { model.stopGroup() },
                            onRename: { model.renamingGroupID = group.id },
                            onSetHotkey: { model.hotkeyGroupID = group.id },
                            onSetMode: { mode in model.setGroupStartMode(mode, for: group.id) }
                        )
                        .overlay(alignment: .top) {
                            if model.groupDropTargetID == group.id {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                        .contextMenu {
                            groupContextMenu(group)
                        }
                        .onDrag {
                            model.trackDropTarget = nil
                            model.playlistDropTargetID = nil
                            model.groupDropTargetID = nil
                            model.beginDragWatch()
                            model.draggingGroupID = group.id
                            model.draggingTrackIDs = []
                            model.draggingPlaylistID = nil
                            return NSItemProvider(object: "group" as NSString)
                        }
                        .onDrop(of: [.plainText, .fileURL],
                                delegate: GroupDropDelegate(groupID: group.id, model: model))
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// Строка трека. Внутри группы строка сдвинута вправо, чтобы дерево читалось.
    private func trackRow(_ track: Track, playlist: Playlist, rowID: String) -> some View {
        TrackRow(
            track: track,
            isCurrent: model.audioEngine.currentTrack?.id == track.id,
            isSelected: model.selection.isSelected(track.id),
            playlistColor: playlist.color,
            indent: track.groupID == nil ? 0 : 18,
            onClick: { modifiers in
                handleTrackClick(track.id, modifiers: modifiers, tracks: playlist.tracks)
            }
        )
        .tag(track.id)
        .overlay(alignment: .top) {
            if showsDropLine(above: track.id) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            trackContextMenu(track)
        }
        .onDrag {
            let ids = model.selection.isSelected(track.id) ? Array(model.selection.selectedIDs) : [track.id]
            model.trackDropTarget = nil
            model.playlistDropTargetID = nil
            model.groupDropTargetID = nil
            model.beginDragWatch()
            model.draggingTrackIDs = ids
            model.draggingGroupID = nil
            model.draggingPlaylistID = nil

            // Провайдеру отдаём сам файл: тогда Finder скопирует трек целиком,
            // сохранив оригинальное расширение, а не создаст .textClipping.
            let provider = NSItemProvider(contentsOf: track.url) ?? NSItemProvider()
            // Имя файла в Finder: только базовое имя, без расширения. Расширение
            // Finder добавляет сам по типу файла, поэтому получается Song.mp3.
            provider.suggestedName = track.url.deletingPathExtension().lastPathComponent
            // Метка для внутренних перемещений: видна только нашему процессу.
            provider.registerObject("tracks" as NSString, visibility: .ownProcess)
            return provider
        }
        .onDrop(of: [.plainText, .fileURL],
                delegate: TrackDropDelegate(
                    targetRowID: rowID,
                    targetIndex: playlist.tracks.firstIndex(where: { $0.id == track.id }) ?? 0,
                    targetID: track.id,
                    model: model))
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
    }

    /// Группа, в которую входит трек.
    private func trackGroupID(for trackID: UUID) -> UUID? {
        model.selectedPlaylist?.tracks.first(where: { $0.id == trackID })?.groupID
    }

    /// Все указанные треки уже в этой группе.
    private func idsAllBelongToSameGroup(_ ids: [UUID], groupID: UUID) -> Bool {
        guard let playlist = model.selectedPlaylist else { return false }
        return ids.allSatisfy { id in
            playlist.tracks.contains { $0.id == id && $0.groupID == groupID }
        }
    }

    /// Играет ли сейчас группа. В режиме «все сразу» это её собственный признак,
    /// иначе — если играет один из её треков.
    private func isGroupPlaying(_ group: TrackGroup, playlist: Playlist) -> Bool {
        if model.audioEngine.playingGroupID == group.id { return true }
        guard let currentID = model.audioEngine.currentTrack?.id else { return false }
        return playlist.tracks.contains { $0.id == currentID && $0.groupID == group.id }
    }

    private func groupContextMenu(_ group: TrackGroup) -> some View {
        Group {
            Button("Запустить группу") { model.playGroup(id: group.id) }
            Button("Остановить группу") { model.stopGroup() }

            Divider()

            Menu("Режим запуска") {
                ForEach(GroupStartMode.allCases) { mode in
                    Button {
                        model.setGroupStartMode(mode, for: group.id)
                    } label: {
                        Text(group.startMode == mode ? "✓ \(mode.title)" : mode.title)
                    }
                }
            }

            Button(group.isExpanded ? "Свернуть" : "Развернуть") {
                model.toggleGroupExpanded(group.id)
            }

            Button("Переименовать") { model.renamingGroupID = group.id }
            Button("Горячая клавиша") { model.hotkeyGroupID = group.id }

            Divider()

            Button("Разъединить группу") { model.ungroup(group.id) }
            Button("Удалить группу с треками", role: .destructive) { model.deleteGroup(group.id) }
        }
    }

    /// Нужно ли рисовать синюю линию над строкой трека с данным ID.
    private func showsDropLine(above trackID: UUID) -> Bool {
        guard let target: (id: UUID, before: Bool) = model.trackDropTarget else { return false }
        return target.id == trackID && target.before
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("В плейлисте пока нет треков")
                .foregroundStyle(.secondary)
            Text("Перетащите аудиофайлы сюда или нажмите «Добавить»")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Добавить треки") { addTracks() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Выделение

    private func handleTrackClick(_ id: UUID, modifiers: EventModifiers, tracks: [Track]) {
        let orderedIDs = tracks.map(\.id)

        if modifiers.contains(.command) {
            model.selection.toggle(id)
        } else if modifiers.contains(.shift) {
            model.selection.selectRange(to: id, in: orderedIDs)
        } else {
            model.selection.selectSingle(id)
        }
    }

    // MARK: - Контекстное меню

    @ViewBuilder
    private func trackContextMenu(_ track: Track) -> some View {
        Button("Воспроизвести") {
            model.play(track: track)
        }

        // Объединение выделенных треков в группу.
        if model.selection.count > 1 {
            Button("Объединить выделенные в группу") {
                model.createGroupFromSelection()
            }
        }

        if !model.selectedPlaylistGroups.isEmpty {
            Menu("Поместить в группу") {
                ForEach(model.selectedPlaylistGroups) { group in
                    Button(group.name) {
                        let ids = model.selection.isSelected(track.id)
                            ? Array(model.selection.selectedIDs) : [track.id]
                        model.setGroup(group.id, for: ids)
                    }
                }
                Divider()
                Button("Убрать из группы") {
                    let ids = model.selection.isSelected(track.id)
                        ? Array(model.selection.selectedIDs) : [track.id]
                    model.setGroup(nil, for: ids)
                }
            }
        }

        Button("Показать в Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([track.url])
        }

        Divider()

        Menu("Переместить в плейлист") {
            ForEach(model.playlistsSorted.filter { $0.id != model.selectedPlaylistID }) { pl in
                Button(pl.name) {
                    let ids = model.selection.isSelected(track.id) ? Array(model.selection.selectedIDs) : [track.id]
                    model.moveTracksToPlaylist(trackIDs: ids, targetPlaylistID: pl.id)
                }
            }
        }

        Divider()

        Menu("Изменить цвет") {
            ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { item in
                Button {
                    if model.selection.isSelected(track.id) && model.selection.count > 1 {
                        model.setColorForSelected(item.element)
                    } else {
                        model.setTrackColor(item.element, for: track.id)
                    }
                } label: {
                    Text(Self.colorEmoji(item.offset))
                }
            }
            Divider()
            Button("Сбросить цвет") {
                if model.selection.isSelected(track.id) && model.selection.count > 1 {
                    model.setColorForSelected(nil)
                } else {
                    model.setTrackColor(nil, for: track.id)
                }
            }
        }

        Button(track.deleteAfterPlay ? "Не удалять после проигрывания" : "Удалять после проигрывания") {
            if model.selection.isSelected(track.id) && model.selection.count > 1 {
                model.toggleDeleteAfterPlayForSelected()
            } else {
                model.toggleDeleteAfterPlay(for: track.id)
            }
        }

        Button("Сбросить обрезку") {
            model.resetTrim(for: track.id)
        }

        Divider()

        Button("Переместить выше") {
            model.moveTrackUp(id: track.id)
        }
        Button("Переместить ниже") {
            model.moveTrackDown(id: track.id)
        }

        Divider()

        Button("Удалить трек", role: .destructive) {
            if model.selection.isSelected(track.id) && model.selection.count > 1 {
                model.removeSelectedTracks()
            } else {
                model.removeTrack(id: track.id)
            }
        }
    }

    // MARK: - Drag and drop файлов

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        // Перетаскивание внутри плеера своим обработчиком не занимается: файлы
        // из Finder обрабатываются только когда ничего не тянется.
        guard model.draggingTrackIDs.isEmpty, model.draggingPlaylistID == nil else { return false }

        let fileType = UTType.fileURL.identifier
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(fileType) }
        guard !matching.isEmpty else { return false }

        Task {
            var urls: [URL] = []
            for provider in matching {
                if let data = try? await provider.loadItem(forTypeIdentifier: fileType) as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }

            // Проверку файлов делаем вне главного потока: открытие файла — операция
            // с диском и не должна подвешивать интерфейс.
            let candidates = urls
            let collected = await Task.detached(priority: .userInitiated) { () -> [URL] in
                candidates.filter { AudioFileSupport.canOpen($0) }
            }.value

            if !collected.isEmpty {
                await MainActor.run {
                    model.addTracks(urls: collected)
                }
            }
        }
        return true
    }

    // MARK: - Перетаскивание порядка треков

    /// Цветной кружок (эмодзи) для пункта меню, в порядке RGBAColor.palette.
    static func colorEmoji(_ index: Int) -> String {
        let circles = ["🔵", "🔴", "🟢", "🟠", "🟣", "💧", "💗", "⚫", "🟡", "🟤"]
        return circles[index % circles.count]
    }

    /// Кружок цвета для пункта меню (не template, чтобы macOS не сделал его серым).
    static func colorDotImage(_ color: RGBAColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func addTracks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.title = "Выберите аудиофайлы"
        if panel.runModal() == .OK {
            model.addTracks(urls: panel.urls)
        }
    }

    /// Суммарная длительность плейлиста с учётом trim-точек.
    private func playlistDuration(_ playlist: Playlist) -> String {
        let total = playlist.tracks.reduce(0.0) { $0 + $1.effectiveDuration }
        return total.timecode
    }
}

// MARK: - Строка трека

private struct TrackRow: View {

    let track: Track
    let isCurrent: Bool
    let isSelected: Bool
    let playlistColor: RGBAColor
    /// Отступ слева: треки внутри группы показываются с отступом.
    var indent: CGFloat = 0
    let onClick: (EventModifiers) -> Void

    @EnvironmentObject private var model: AppModel
    @State private var isHovering = false

    private var effectiveColor: RGBAColor {
        track.color ?? playlistColor
    }

    /// Файл трека отсутствует (следит модель, поэтому значок обновляется сразу).
    private var isMissing: Bool {
        model.isMissing(track.id)
    }

    private var rowIconName: String {
        if isMissing { return "exclamationmark.triangle.fill" }
        return isCurrent ? "speaker.wave.2.fill" : "music.note"
    }

    private var rowIconColor: Color {
        if isMissing { return Color.red }
        return isCurrent ? effectiveColor.swiftUIColor : Color.secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            // Файл исчез с диска — вместо ноты показываем предупреждение.
            Image(systemName: rowIconName)
                .foregroundStyle(rowIconColor)
                .frame(width: 16)
                .help(isMissing ? "Файл не найден: \(track.path)" : track.name)

            RoundedRectangle(cornerRadius: 2)
                .fill(effectiveColor.swiftUIColor)
                .frame(width: 3, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.name)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(isMissing ? Color.red : Color.secondary)

                    if track.deleteAfterPlay {
                        Text("• удалить после проигрывания")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                    }

                    if track.trimStart > 0 || track.trimEnd != nil {
                        Text("• обрезка")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.cyan)
                    }
                }
                .lineLimit(1)
            }

            Spacer()

            Text(track.effectiveDuration.timecode)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .padding(.leading, 6 + indent)
        .padding(.trailing, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.play(track: track)
        }
        .onTapGesture(count: 1) {
            onClick(currentModifiers())
        }
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected {
            return effectiveColor.swiftUIColor.opacity(0.25)
        }
        return isHovering ? Color.secondary.opacity(0.08) : Color.clear
    }

    private var detail: String {
        !isMissing ? track.url.deletingLastPathComponent().lastPathComponent : "файл не найден"
    }


    /// NSEvent.ModifierFlags и SwiftUI EventModifiers — разные типы,
    /// поэтому переносим флаги вручную.
    private func currentModifiers() -> EventModifiers {
        let flags = NSEvent.modifierFlags
        var result: EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}

/// Перестановка треков перетаскиванием: трек вставляется перед строкой, на которую бросили.
struct TrackDropDelegate: DropDelegate {
    /// ID строки списка (трек или группа) — по ней определяется место вставки.
    let targetRowID: String
    let targetIndex: Int
    let targetID: UUID
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        !model.draggingTrackIDs.isEmpty
    }

    /// Трек вставляется ПЕРЕД строкой, над которой отпущен. Линия рисуется
    /// над строкой — ровно там, где окажется трек.
    func dropEntered(info: DropInfo) {
        showIndicator()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        showIndicator()
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.trackDropTarget?.id == targetID {
            model.trackDropTarget = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        // Сбрасываем состояние при любом исходе: и при переносе, и при отказе.
        defer { model.endDragging() }

        // Перетаскивание группы на строку трека: группа встаёт к этому треку.
        if let groupID = model.draggingGroupID {
            model.moveGroup(groupID: groupID, ontoTrackRow: targetID)
            return true
        }

        let ids = model.draggingTrackIDs
        guard !ids.isEmpty, !ids.contains(targetID) else { return false }

        // Внутри группы перенос меняет порядок её треков, поэтому группа
        // сохраняется. При обычном переносе трек выходит из своей группы.
        let targetGroupID = trackGroupID(for: targetID)
        if let groupID = targetGroupID, idsAllBelongToSameGroup(ids, groupID: groupID) {
            model.moveTracks(ids: ids, ontoTrackRow: targetID, above: true)
        } else if let groupID = targetGroupID {
            // Бросок на трек группы: треки входят в эту группу.
            model.setGroup(groupID, for: ids)
        } else {
            model.moveTracks(ids: ids, ontoTrackRow: targetID, above: true)
        }
        return true
    }

    private func showIndicator() {
        // Перетаскивание уже завершено — линию не показываем. Без этой проверки
        // dropUpdated, приходящий после performDrop при перестройке списка,
        // зажигал бы линию заново.
        guard !model.draggingTrackIDs.isEmpty || model.draggingGroupID != nil else {
            model.trackDropTarget = nil
            model.groupDropTargetID = nil
            return
        }
        // Не показываем линию, если строка — сам перетаскиваемый трек: переносить некуда.
        guard !model.draggingTrackIDs.contains(targetID) else {
            model.trackDropTarget = nil
            return
        }
        // Запись только при изменении, чтобы не перерисовывать список на каждом кадре.
        if model.trackDropTarget?.id != targetID || model.trackDropTarget?.before != true {
            model.trackDropTarget = (targetID, true)
        }
    }
}

// MARK: - Поддержка аудиоформатов

/// Проверка форматов вынесена из View: внутри `View` методы неявно привязаны к
/// главному актору, а открытие файла должно выполняться в фоновом потоке.
enum AudioFileSupport {

    /// Расширения, которые macOS умеет декодировать (AVFoundation + системные кодеки).
    static let audioExtensions: Set<String> = [
        "mp3", "wav", "wave", "m4a", "m4b", "m4r", "aac", "adts", "flac",
        "aif", "aiff", "aifc", "caf", "alac", "au", "snd", "mp2", "mp1",
        "ac3", "eac3", "amr", "mp4", "m4v", "mov", "3gp", "3g2", "sd2", "opus"
    ]

    /// Знакомое расширение принимается сразу, незнакомое проверяется открытием файла.
    nonisolated static func canOpen(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return true }
        return AudioEngine.canOpen(url)
    }
}

// MARK: - Строка группы

/// Строка группы в дереве списка: стрелка сворачивания, название, режим запуска
/// и кнопки управления. Треки группы идут под ней с отступом.
private struct GroupRow: View {

    let group: TrackGroup
    let trackCount: Int
    let isPlaying: Bool
    let isHoveredDropTarget: Bool
    let onToggleExpand: () -> Void
    let onPlay: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void
    let onRename: () -> Void
    let onSetHotkey: () -> Void
    let onSetMode: (GroupStartMode) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleExpand) {
                Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(group.isExpanded ? "Свернуть группу" : "Развернуть группу")

            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 11))
                .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(trackCount) трек(ов)")
                    Text("·")
                    Text(group.startMode.title)
                    if let hotkey = group.hotkey {
                        Text("·")
                        Text(hotkey.display).foregroundStyle(Color.accentColor)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            // Кнопки управления группой: старт, пауза, стоп каскадом по всем трекам.
            HStack(spacing: 4) {
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "Пауза группы" : "Запустить группу")

                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Остановить группу")

                Menu {
                    ForEach(GroupStartMode.allCases) { mode in
                        Button {
                            onSetMode(mode)
                        } label: {
                            Text(group.startMode == mode ? "✓ \(mode.title)" : mode.title)
                        }
                    }
                } label: {
                    Image(systemName: group.startMode.symbolName)
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Режим запуска группы")

                Menu {
                    Button("Переименовать", action: onRename)
                    Button("Горячая клавиша", action: onSetHotkey)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Действия группы")
            }
            .opacity(isHovering || isPlaying ? 1 : 0.55)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isPlaying ? Color.accentColor.opacity(0.18)
                      : (isHovering ? Color.secondary.opacity(0.08) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onToggleExpand() }
        .onHover { isHovering = $0 }
    }
}

// MARK: - Перетаскивание на строку группы

/// Трек, брошенный на группу, становится её частью. Группа, брошенная на группу,
/// встаёт рядом с ней.
struct GroupDropDelegate: DropDelegate {

    let groupID: UUID
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        model.draggingGroupID != nil || !model.draggingTrackIDs.isEmpty
    }

    func dropEntered(info: DropInfo) {
        showIndicator()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        showIndicator()
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.groupDropTargetID == groupID {
            model.groupDropTargetID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { model.endDragging() }

        if let draggedGroup = model.draggingGroupID {
            guard draggedGroup != groupID else { return false }
            model.moveGroup(groupID: draggedGroup, ontoGroup: groupID)
            return true
        }

        let ids = model.draggingTrackIDs
        guard !ids.isEmpty else { return false }
        model.setGroup(groupID, for: ids)
        return true
    }

    private func showIndicator() {
        guard model.draggingGroupID != nil || !model.draggingTrackIDs.isEmpty else {
            model.groupDropTargetID = nil
            return
        }
        guard model.draggingGroupID != groupID else {
            model.groupDropTargetID = nil
            return
        }
        if model.groupDropTargetID != groupID {
            model.groupDropTargetID = groupID
        }
    }
}

// MARK: - Лист переименования группы

private struct GroupRenameSheet: View {

    let group: TrackGroup
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Название группы").font(.headline)

            TextField("Название", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($isFocused)

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    onSave(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .onAppear {
            name = group.name
            isFocused = true
        }
    }
}

// MARK: - Лист горячей клавиши группы

/// Захват комбинации клавиш. Пока лист открыт, нажатие перехватывается здесь,
/// поэтому конфликты с обычными горячими клавишами плеера не возникают.
private struct GroupHotkeySheet: View {

    let group: TrackGroup
    let onSave: (GroupHotkey?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var captured: GroupHotkey?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Горячая клавиша").font(.headline)
            Text("Нажмите комбинацию с Shift, Control или Command — например ⌃⌥1.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(captured?.display ?? "ожидание нажатия…")
                .font(.system(size: 15, design: .monospaced))
                .frame(width: 240, height: 30)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))

            HStack {
                if group.hotkey != nil {
                    Button("Снять") {
                        onSave(nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    onSave(captured)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(captured == nil)
            }
        }
        .padding(18)
        .onAppear { startCapture() }
        .onDisappear { stopCapture() }
    }

    private func startCapture() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Без модификатора комбинация перехватывала бы обычный ввод.
            let hasModifier = !flags.intersection([.command, .control, .option, .shift]).isEmpty
            guard hasModifier else { return event }

            captured = GroupHotkey(keyCode: event.keyCode,
                                   modifiersRaw: flags.rawValue,
                                   display: Self.describe(event: event, flags: flags))
            return nil
        }
    }

    private func stopCapture() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Читаемое обозначение комбинации для интерфейса.
    private static func describe(event: NSEvent, flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        if let characters = event.charactersIgnoringModifiers?.uppercased() {
            text += characters
        }
        return text
    }
}
