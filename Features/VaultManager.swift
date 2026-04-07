import Combine
import Foundation
import UIKit

struct VaultAlbum: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var itemCount: Int
    var isHidden: Bool
    var coverImageId: String?
}

struct VaultMediaItem: Identifiable, Codable, Hashable {
    let id: String
    let albumId: String
    let originalAssetId: String?
    let encryptedFilePath: String
    let thumbnailPath: String
    let mediaType: MediaType
    let createdAt: Date
    let fileSize: Int64
    let encryptionKeyRef: String

    enum MediaType: String, Codable, Hashable {
        case image
    }
}

enum VaultError: LocalizedError {
    case albumNotFound
    case invalidAlbumName
    case invalidMedia
    case unauthorizedAccess
    case importFailed

    var errorDescription: String? {
        switch self {
        case .albumNotFound:
            return "相册不存在。"
        case .invalidAlbumName:
            return "请输入 1 到 40 个字符的相册名称。"
        case .invalidMedia:
            return "只支持导入可解码的图片文件。"
        case .unauthorizedAccess:
            return "未能读取当前保险库的解密密钥。"
        case .importFailed:
            return "导入失败，请重试。"
        }
    }
}

@MainActor
final class VaultManager: ObservableObject {
    static let shared = VaultManager()

    @Published private(set) var albums: [VaultAlbum] = []
    @Published private(set) var mediaItems: [VaultMediaItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var storageUsage: Int64 = 0

    private let encryptionManager = VaultEncryptionManager.shared
    private let keychainManager = KeychainManager.shared
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cancellables = Set<AnyCancellable>()

    private var vaultDirectory: URL {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("PhotoVault", isDirectory: true)
    }

    private var encryptedAssetsDirectory: URL {
        vaultDirectory.appendingPathComponent("encrypted_assets", isDirectory: true)
    }

    private var thumbnailsDirectory: URL {
        vaultDirectory.appendingPathComponent("encrypted_thumbnails", isDirectory: true)
    }

    private var albumsFileURL: URL {
        vaultDirectory.appendingPathComponent("albums.json")
    }

    private var mediaItemsFileURL: URL {
        vaultDirectory.appendingPathComponent("media_items.json")
    }

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        setupDirectories()
        loadPersistedState()
        setupNotifications()
        updateStorageUsage()
    }

    func createAlbum(name: String, isHidden: Bool = false) throws -> VaultAlbum {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 40 else {
            throw VaultError.invalidAlbumName
        }

        let album = VaultAlbum(
            id: UUID().uuidString,
            name: trimmedName,
            createdAt: Date(),
            updatedAt: Date(),
            itemCount: 0,
            isHidden: isHidden,
            coverImageId: nil
        )

        albums.append(album)
        persistState()
        return album
    }

    func deleteAlbum(_ album: VaultAlbum) throws {
        let items = getMediaItems(albumId: album.id)
        for item in items {
            try deleteMediaItem(item)
        }

        albums.removeAll { $0.id == album.id }
        persistState()
    }

    func updateAlbum(_ album: VaultAlbum) throws {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else {
            throw VaultError.albumNotFound
        }

        albums[index] = album
        persistState()
    }

    func getAlbums(includeHidden: Bool = false) -> [VaultAlbum] {
        let source = includeHidden ? albums : albums.filter { !$0.isHidden }
        return source.sorted { $0.updatedAt > $1.updatedAt }
    }

    func getMediaItems(albumId: String) -> [VaultMediaItem] {
        mediaItems
            .filter { $0.albumId == albumId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func importPhoto(to albumId: String, data: Data, sourceIdentifier: String? = nil) throws -> VaultMediaItem {
        guard let originalImage = UIImage(data: data) else {
            throw VaultError.invalidMedia
        }

        guard let albumIndex = albums.firstIndex(where: { $0.id == albumId }) else {
            throw VaultError.albumNotFound
        }

        let thumbnailJPEG = try makeThumbnailData(from: originalImage)
        let fileKey = encryptionManager.generateFileEncryptionKey()
        let keyIdentifier = UUID().uuidString

        let encryptedImageURL = encryptedAssetsDirectory
            .appendingPathComponent(albumId, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).pvenc")

        let encryptedThumbnailURL = thumbnailsDirectory
            .appendingPathComponent(albumId, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).pvthumb")

        try fileManager.createDirectory(
            at: encryptedImageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )

        try fileManager.createDirectory(
            at: encryptedThumbnailURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )

        let encryptedOriginal = try encryptionManager.encryptWithFileKey(data: data, fileKey: fileKey)
        let encryptedThumbnail = try encryptionManager.encryptWithFileKey(data: thumbnailJPEG, fileKey: fileKey)

        try writeProtected(encryptedOriginal.encryptedData, to: encryptedImageURL)
        try writeProtected(encryptedThumbnail.encryptedData, to: encryptedThumbnailURL)

        let wrappedKey = try encryptionManager.wrapFileKey(fileKey)
        try keychainManager.store(data: wrappedKey, identifier: "filekey_\(keyIdentifier)")

        let mediaItem = VaultMediaItem(
            id: UUID().uuidString,
            albumId: albumId,
            originalAssetId: sourceIdentifier,
            encryptedFilePath: encryptedImageURL.path,
            thumbnailPath: encryptedThumbnailURL.path,
            mediaType: .image,
            createdAt: Date(),
            fileSize: Int64(encryptedOriginal.encryptedData.count),
            encryptionKeyRef: keyIdentifier
        )

        mediaItems.append(mediaItem)
        albums[albumIndex].itemCount += 1
        albums[albumIndex].updatedAt = Date()
        albums[albumIndex].coverImageId = mediaItem.id

        persistState()
        updateStorageUsage()
        return mediaItem
    }

    func deleteMediaItem(_ item: VaultMediaItem) throws {
        try? fileManager.removeItem(atPath: item.encryptedFilePath)
        try? fileManager.removeItem(atPath: item.thumbnailPath)
        keychainManager.delete(identifier: "filekey_\(item.encryptionKeyRef)")
        mediaItems.removeAll { $0.id == item.id }
        refreshAlbumStatistics(for: item.albumId)
        persistState()
        updateStorageUsage()
    }

    func thumbnailImage(for item: VaultMediaItem) throws -> UIImage {
        let data = try decryptFile(atPath: item.thumbnailPath, keyReference: item.encryptionKeyRef)
        guard let image = UIImage(data: data) else {
            throw VaultError.invalidMedia
        }
        return image
    }

    func image(for item: VaultMediaItem) throws -> UIImage {
        let data = try decryptFile(atPath: item.encryptedFilePath, keyReference: item.encryptionKeyRef)
        guard let image = UIImage(data: data) else {
            throw VaultError.invalidMedia
        }
        return image
    }

    func performEmergencyWipe() {
        try? fileManager.removeItem(at: vaultDirectory)
        keychainManager.deleteAll()
        albums = []
        mediaItems = []
        storageUsage = 0
        setupDirectories()
    }

    private func decryptFile(atPath path: String, keyReference: String) throws -> Data {
        guard let wrappedKey = try keychainManager.retrieveData(identifier: "filekey_\(keyReference)") else {
            throw VaultError.unauthorizedAccess
        }

        let fileKey = try encryptionManager.unwrapFileKey(from: wrappedKey)
        let encryptedData = try Data(contentsOf: URL(fileURLWithPath: path))
        let decrypted = try encryptionManager.decryptWithFileKey(data: encryptedData, fileKey: fileKey)
        return decrypted.decryptedData
    }

    private func refreshAlbumStatistics(for albumId: String) {
        guard let albumIndex = albums.firstIndex(where: { $0.id == albumId }) else { return }
        let items = getMediaItems(albumId: albumId)
        albums[albumIndex].itemCount = items.count
        albums[albumIndex].updatedAt = Date()
        albums[albumIndex].coverImageId = items.first?.id
    }

    private func makeThumbnailData(from image: UIImage) throws -> Data {
        let targetSize = CGSize(width: 600, height: 600)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let thumbnail = renderer.image { _ in
            UIColor.secondarySystemBackground.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: targetSize)).fill()

            let aspectWidth = targetSize.width / image.size.width
            let aspectHeight = targetSize.height / image.size.height
            let scale = min(aspectWidth, aspectHeight)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(
                x: (targetSize.width - drawSize.width) / 2,
                y: (targetSize.height - drawSize.height) / 2
            )

            image.draw(in: CGRect(origin: origin, size: drawSize))
        }

        guard let data = thumbnail.jpegData(compressionQuality: 0.78) else {
            throw VaultError.importFailed
        }

        return data
    }

    private func loadPersistedState() {
        if let albumData = try? Data(contentsOf: albumsFileURL),
           let decodedAlbums = try? decoder.decode([VaultAlbum].self, from: albumData) {
            albums = decodedAlbums
        }

        if let mediaData = try? Data(contentsOf: mediaItemsFileURL),
           let decodedMediaItems = try? decoder.decode([VaultMediaItem].self, from: mediaData) {
            mediaItems = decodedMediaItems
        }
    }

    private func persistState() {
        if let albumData = try? encoder.encode(albums) {
            try? writeProtected(albumData, to: albumsFileURL)
        }

        if let mediaData = try? encoder.encode(mediaItems) {
            try? writeProtected(mediaData, to: mediaItemsFileURL)
        }
    }

    private func setupDirectories() {
        let directories = [vaultDirectory, encryptedAssetsDirectory, thumbnailsDirectory]
        for directory in directories {
            try? fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
    }

    private func updateStorageUsage() {
        storageUsage = directorySize(at: encryptedAssetsDirectory) + directorySize(at: thumbnailsDirectory)
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += Int64(size ?? 0)
        }
        return total
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .securityResetTriggered)
            .sink { [weak self] _ in
                self?.performEmergencyWipe()
            }
            .store(in: &cancellables)
    }
}
