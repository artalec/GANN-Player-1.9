import Foundation

// MARK: - Track

struct Track: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var duration: TimeInterval

    // Новые поля для расширенного функционала
    var color: RGBAColor?              // Цвет выделения трека (nil = цвет плейлиста)
    var trimStart: TimeInterval        // Точка начала воспроизведения (Audio Trim)
    var trimEnd: TimeInterval?         // Точка окончания (nil = до конца файла)
    var deleteAfterPlay: Bool          // Удалить трек после полного проигрывания
    var groupID: UUID?                 // Группа трека (nil = трек стоит в списке сам по себе)

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    // Эффективная длительность с учётом trim
    var effectiveDuration: TimeInterval {
        let end = trimEnd ?? duration
        return max(0, end - trimStart)
    }

    /// Декодер с значениями по умолчанию: файл состояния, сохранённый предыдущей
    /// версией приложения, не содержит новых полей.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        color = try c.decodeIfPresent(RGBAColor.self, forKey: .color)
        trimStart = try c.decodeIfPresent(TimeInterval.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(TimeInterval.self, forKey: .trimEnd)
        deleteAfterPlay = try c.decodeIfPresent(Bool.self, forKey: .deleteAfterPlay) ?? false
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
    }

    init(id: UUID = UUID(),
         name: String,
         path: String,
         duration: TimeInterval = 0,
         color: RGBAColor? = nil,
         trimStart: TimeInterval = 0,
         trimEnd: TimeInterval? = nil,
         deleteAfterPlay: Bool = false,
         groupID: UUID? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.duration = duration
        self.color = color
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.deleteAfterPlay = deleteAfterPlay
        self.groupID = groupID
    }

    init(url: URL, duration: TimeInterval = 0) {
        self.id = UUID()
        self.name = url.deletingPathExtension().lastPathComponent
        self.path = url.path
        self.duration = duration
        self.color = nil
        self.trimStart = 0
        self.trimEnd = nil
        self.deleteAfterPlay = false
        self.groupID = nil
    }
}

// MARK: - Track group

/// Как группа запускает свои треки.
enum GroupStartMode: String, Codable, CaseIterable, Identifiable {
    /// Старт всех треков группы одновременно.
    case allAtOnce
    /// Старт первого трека из списка группы.
    case firstTrack
    /// Старт случайного трека из группы.
    case randomTrack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allAtOnce: return "Все сразу"
        case .firstTrack: return "Первый трек"
        case .randomTrack: return "Случайный трек"
        }
    }

    var symbolName: String {
        switch self {
        case .allAtOnce: return "square.stack.3d.up.fill"
        case .firstTrack: return "arrow.down.to.line"
        case .randomTrack: return "shuffle"
        }
    }
}

/// Горячая клавиша запуска группы.
struct GroupHotkey: Codable, Hashable {
    var keyCode: UInt16
    /// Модификаторы в сыром виде (NSEvent.ModifierFlags.rawValue).
    var modifiersRaw: UInt
    /// Как клавиши показывать в интерфейсе, например «⌃⌥1».
    var display: String
}

/// Группа треков внутри плейлиста. Треки остаются в общем массиве плейлиста,
/// а принадлежность к группе хранится в самом треке (Track.groupID).
struct TrackGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var startMode: GroupStartMode
    var isExpanded: Bool
    var hotkey: GroupHotkey?

    init(id: UUID = UUID(),
         name: String,
         startMode: GroupStartMode = .firstTrack,
         isExpanded: Bool = true,
         hotkey: GroupHotkey? = nil) {
        self.id = id
        self.name = name
        self.startMode = startMode
        self.isExpanded = isExpanded
        self.hotkey = hotkey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Группа"
        startMode = try c.decodeIfPresent(GroupStartMode.self, forKey: .startMode) ?? .firstTrack
        isExpanded = try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        hotkey = try c.decodeIfPresent(GroupHotkey.self, forKey: .hotkey)
    }
}

/// Одна строка списка плейлиста: либо отдельный трек, либо группа.
/// Порядок строк хранится отдельно от порядка треков, чтобы треки группы
/// оставались соседними и внутри группы сохранялся свой порядок.
enum PlaylistOrderItem: Codable, Hashable, Identifiable {
    case track(UUID)
    case group(UUID)

    var id: String {
        switch self {
        case .track(let id): return "t-\(id.uuidString)"
        case .group(let id): return "g-\(id.uuidString)"
        }
    }

    var trackID: UUID? {
        if case .track(let id) = self { return id }
        return nil
    }

    var groupID: UUID? {
        if case .group(let id) = self { return id }
        return nil
    }
}

// MARK: - Playlist

struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var tracks: [Track]
    var color: RGBAColor
    var order: Int

    // Новые поля для расширенного функционала
    var loopEnabled: Bool              // Зацикливание плейлиста
    var autoplayEnabled: Bool          // Автопереход на следующий трек
    var groups: [TrackGroup]           // Группы треков внутри плейлиста
    var rowOrder: [PlaylistOrderItem]  // Порядок строк списка: треки и группы вперемешку

    /// Декодер с значениями по умолчанию: файл состояния прежней версии не
    /// содержит групп и порядка строк, без этого плейлисты не прочитались бы.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        color = try c.decodeIfPresent(RGBAColor.self, forKey: .color)
            ?? RGBAColor(red: 0.20, green: 0.55, blue: 1.0)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        loopEnabled = try c.decodeIfPresent(Bool.self, forKey: .loopEnabled) ?? false
        autoplayEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoplayEnabled) ?? true
        groups = try c.decodeIfPresent([TrackGroup].self, forKey: .groups) ?? []
        rowOrder = try c.decodeIfPresent([PlaylistOrderItem].self, forKey: .rowOrder) ?? []
    }

    init(id: UUID = UUID(),
         name: String,
         tracks: [Track] = [],
         color: RGBAColor = RGBAColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1.0),
         order: Int = 0,
         loopEnabled: Bool = false,
         autoplayEnabled: Bool = true,
         groups: [TrackGroup] = [],
         rowOrder: [PlaylistOrderItem] = []) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.color = color
        self.order = order
        self.loopEnabled = loopEnabled
        self.autoplayEnabled = autoplayEnabled
        self.groups = groups
        self.rowOrder = rowOrder
    }
}

// MARK: - Codable color

struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    static let palette: [RGBAColor] = [
        RGBAColor(red: 0.20, green: 0.55, blue: 1.00),
        RGBAColor(red: 1.00, green: 0.27, blue: 0.35),
        RGBAColor(red: 0.15, green: 0.80, blue: 0.45),
        RGBAColor(red: 1.00, green: 0.65, blue: 0.10),
        RGBAColor(red: 0.65, green: 0.35, blue: 0.95),
        RGBAColor(red: 0.10, green: 0.75, blue: 0.85),
        RGBAColor(red: 0.95, green: 0.45, blue: 0.75),
        RGBAColor(red: 0.40, green: 0.40, blue: 0.40),
        RGBAColor(red: 0.95, green: 0.95, blue: 0.20),
        RGBAColor(red: 0.85, green: 0.45, blue: 0.25)
    ]
}

// MARK: - Settings

struct AppSettings: Codable {
    var crossfadeEnabled: Bool = false
    var crossfadeDuration: Double = 3.0
    var highCutEnabled: Bool = false
    var highCutDuration: Double = 2.0
    var highCutPauseAfter: Double = 0.0    // Пауза после high-cut перед запуском следующего
    var volume: Double = 1.0               // Громкость 0...1
    var loopTrackEnabled: Bool = false     // Зацикливание текущего трека
    var focusFadeEnabled: Bool = false     // Focus Fade: пауза при уходе из плеера
    var focusFadeDuration: Double = 1.5    // Время плавного срабатывания Focus Fade

    init() {}

    init(crossfadeEnabled: Bool,
         crossfadeDuration: Double,
         highCutEnabled: Bool,
         highCutDuration: Double,
         highCutPauseAfter: Double = 0.0,
         volume: Double = 1.0) {
        self.crossfadeEnabled = crossfadeEnabled
        self.crossfadeDuration = crossfadeDuration
        self.highCutEnabled = highCutEnabled
        self.highCutDuration = highCutDuration
        self.highCutPauseAfter = highCutPauseAfter
        self.volume = volume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crossfadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossfadeEnabled) ?? false
        crossfadeDuration = try c.decodeIfPresent(Double.self, forKey: .crossfadeDuration) ?? 3.0
        highCutEnabled = try c.decodeIfPresent(Bool.self, forKey: .highCutEnabled) ?? false
        highCutDuration = try c.decodeIfPresent(Double.self, forKey: .highCutDuration) ?? 2.0
        highCutPauseAfter = try c.decodeIfPresent(Double.self, forKey: .highCutPauseAfter) ?? 0.0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        focusFadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .focusFadeEnabled) ?? false
        focusFadeDuration = try c.decodeIfPresent(Double.self, forKey: .focusFadeDuration) ?? 1.5
    }
}

// MARK: - Persisted application state

struct AppState: Codable {
    var playlists: [Playlist]
    var settings: AppSettings
    var selectedPlaylistID: UUID?

    init(playlists: [Playlist], settings: AppSettings, selectedPlaylistID: UUID?) {
        self.playlists = playlists
        self.settings = settings
        self.selectedPlaylistID = selectedPlaylistID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playlists = try c.decodeIfPresent([Playlist].self, forKey: .playlists) ?? [Playlist(name: "Плейлист 1", order: 0)]
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        selectedPlaylistID = try c.decodeIfPresent(UUID.self, forKey: .selectedPlaylistID)
    }

    static func fresh() -> AppState {
        let first = Playlist(name: "Плейлист 1", order: 0)
        return AppState(playlists: [first], settings: AppSettings(), selectedPlaylistID: first.id)
    }
}
