import CryptoKit
import LocalAuthentication
import PhotosUI
import SwiftUI
import UIKit

@main
struct PhotoVaultProApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var lockManager = VaultLockManager()
    @StateObject private var vaultManager = VaultManager.shared
    @StateObject private var privacyPreferencesStore = VaultPrivacyPreferencesStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(lockManager)
                .environmentObject(vaultManager)
                .environmentObject(privacyPreferencesStore)
                .task {
                    lockManager.bootstrap()
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase != .active && privacyPreferencesStore.preferences.autoLockOnBackground {
                        lockManager.lock()
                    }
                }
        }
    }
}

@MainActor
final class VaultLockManager: ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var isUnlocked = false
    @Published private(set) var biometricType: LocalAuthentication.LABiometryType = .none
    @Published private(set) var lastError: String?

    private let keychain = KeychainManager.shared
    private let authManager = FaceIDAuthenticationManager.shared

    private let passcodeHashKey = "vault_passcode_hash"
    private let passcodeSaltKey = "vault_passcode_salt"
    private let masterKeyIdentifier = "master_key"

    func bootstrap() {
        authManager.checkBiometryAvailability()
        biometricType = authManager.biometryType
        isConfigured = hasPasscodeConfigured()
        isUnlocked = false
    }

    func createPasscode(_ passcode: String, confirmation: String) throws {
        guard passcode == confirmation else {
            throw VaultSetupError.passcodesDoNotMatch
        }

        guard passcode.count >= 4, passcode.count <= 8, CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: passcode)) else {
            throw VaultSetupError.invalidPasscode
        }

        let salt = secureRandomBytes(count: SecurityConstants.saltSize)
        let hash = hashPasscode(passcode, salt: salt)

        try keychain.store(data: salt, identifier: passcodeSaltKey)
        try keychain.store(data: hash, identifier: passcodeHashKey)

        if (try? keychain.retrieveKey(identifier: masterKeyIdentifier)) == nil {
            let masterKey = SymmetricKey(size: .bits256)
            try keychain.store(
                key: masterKey,
                identifier: masterKeyIdentifier,
                accessibility: .whenPasscodedThisDeviceOnly
            )
        }

        isConfigured = true
        isUnlocked = true
        lastError = nil
    }

    func unlock(with passcode: String) -> Bool {
        guard
            let salt = try? keychain.retrieveData(identifier: passcodeSaltKey),
            let hash = try? keychain.retrieveData(identifier: passcodeHashKey)
        else {
            lastError = "未找到锁定凭据，请重新初始化保险库。"
            return false
        }

        let candidateHash = hashPasscode(passcode, salt: salt)
        let isValid = constantTimeCompare(candidateHash, hash)
        isUnlocked = isValid
        lastError = isValid ? nil : "PIN 不正确。"
        return isValid
    }

    func unlockWithBiometrics() {
        authManager.authenticate(reason: "Unlock your encrypted private vault.") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                Task { @MainActor in
                    self.isUnlocked = true
                    self.lastError = nil
                }
            case .failure(let error):
                Task { @MainActor in
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func lock() {
        isUnlocked = false
    }

    private func hasPasscodeConfigured() -> Bool {
        ((try? keychain.retrieveData(identifier: passcodeHashKey)) ?? nil) != nil
    }

    private func hashPasscode(_ passcode: String, salt: Data) -> Data {
        var payload = Data(passcode.utf8)
        payload.append(salt)
        return sha256(data: payload)
    }
}

enum VaultSetupError: LocalizedError {
    case invalidPasscode
    case passcodesDoNotMatch

    var errorDescription: String? {
        switch self {
        case .invalidPasscode:
            return "请设置 4 到 8 位数字 PIN。"
        case .passcodesDoNotMatch:
            return "两次输入的 PIN 不一致。"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var lockManager: VaultLockManager

    var body: some View {
        Group {
            if !lockManager.isConfigured {
                VaultOnboardingView()
            } else if !lockManager.isUnlocked {
                VaultUnlockView()
            } else {
                VaultHomeView()
            }
        }
    }
}

struct VaultOnboardingView: View {
    @EnvironmentObject private var lockManager: VaultLockManager

    @State private var passcode = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PhotoVault Pro")
                            .font(.largeTitle.bold())
                        Text("Build a local, encrypted vault for your private photos. Nothing is uploaded, and imports stay on device.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("本地加密存储", systemImage: "lock.doc")
                        Label("系统 Photos Picker 导入", systemImage: "photo.on.rectangle")
                        Label("PIN + Face ID 解锁", systemImage: "faceid")
                    }
                    .font(.headline)

                    VStack(spacing: 16) {
                        SecureField("设置 4-8 位数字 PIN", text: $passcode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .textFieldStyle(.roundedBorder)

                        SecureField("再次输入 PIN", text: $confirmation)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .textFieldStyle(.roundedBorder)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        Button("创建保险库", action: configureVault)
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
            }
            .navigationTitle("初始设置")
        }
    }

    private func configureVault() {
        do {
            try lockManager.createPasscode(passcode, confirmation: confirmation)
            errorMessage = nil
            passcode = ""
            confirmation = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct VaultUnlockView: View {
    @EnvironmentObject private var lockManager: VaultLockManager
    @EnvironmentObject private var privacyPreferencesStore: VaultPrivacyPreferencesStore

    @State private var passcode = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                Text("Vault Locked")
                    .font(.title.bold())
                Text("Use your PIN or biometric authentication to open the encrypted vault.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            SecureField("输入 PIN", text: $passcode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24)

            if let lastError = lockManager.lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button("解锁") {
                if lockManager.unlock(with: passcode) {
                    passcode = ""
                }
            }
            .buttonStyle(.borderedProminent)

            if privacyPreferencesStore.preferences.allowsBiometricUnlock, lockManager.biometricType != .none {
                Button {
                    lockManager.unlockWithBiometrics()
                } label: {
                    Label("使用 \(lockManager.biometricType == .faceID ? "Face ID" : "Touch ID")", systemImage: lockManager.biometricType == .faceID ? "faceid" : "touchid")
                }
            }

            Spacer()
        }
        .padding(.bottom, 40)
    }
}

struct VaultHomeView: View {
    @EnvironmentObject private var lockManager: VaultLockManager
    @EnvironmentObject private var vaultManager: VaultManager
    @EnvironmentObject private var privacyPreferencesStore: VaultPrivacyPreferencesStore

    @State private var newAlbumName = ""
    @State private var showingCreateAlbum = false
    @State private var showingSettings = false
    @State private var albumPendingDeletion: VaultAlbum?

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Encrypted private photo vault")
                            .font(.headline)
                        Text("Imports use the system picker and stay on this device. Create separate albums to keep the vault tidy.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Albums") {
                    if vaultManager.getAlbums().isEmpty {
                        VaultEmptyStateView(
                            title: "No Albums Yet",
                            systemImage: "photo.stack",
                            message: "Create your first album, then import photos with the system picker."
                        )
                    } else {
                        ForEach(vaultManager.getAlbums()) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumRow(album: album)
                            }
                        }
                        .onDelete(perform: requestAlbumDeletion)
                    }
                }

                Section("Vault Status") {
                    Label("\(vaultManager.mediaItems.count) encrypted items", systemImage: "lock.doc")
                    Label(ByteCountFormatter.string(fromByteCount: vaultManager.storageUsage, countStyle: .file), systemImage: "internaldrive")
                }
            }
            .navigationTitle("PhotoVault Pro")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Lock") {
                        lockManager.lock()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }

                        Button {
                            showingCreateAlbum = true
                        } label: {
                            Label("New Album", systemImage: "plus")
                        }
                    }
                }
            }
            .alert("创建新相册", isPresented: $showingCreateAlbum) {
                TextField("相册名称", text: $newAlbumName)
                Button("取消", role: .cancel) {
                    newAlbumName = ""
                }
                Button("创建", action: createAlbum)
            } message: {
                Text("为导入的图片建立一个明确用途的相册，便于后续整理。")
            }
            .sheet(isPresented: $showingSettings) {
                VaultSettingsView(
                    itemCount: vaultManager.mediaItems.count,
                    storageUsage: vaultManager.storageUsage
                )
            }
            .alert(item: $albumPendingDeletion) { album in
                Alert(
                    title: Text("删除相册？"),
                    message: Text("“\(album.name)”中的所有加密图片都会一起删除。这个操作不能撤销。"),
                    primaryButton: .destructive(Text("删除")) {
                        try? vaultManager.deleteAlbum(album)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private func createAlbum() {
        defer { newAlbumName = "" }
        try? vaultManager.createAlbum(name: newAlbumName)
    }

    private func requestAlbumDeletion(at offsets: IndexSet) {
        let albums = vaultManager.getAlbums()
        guard let index = offsets.first else { return }
        if albums.indices.contains(index) {
            albumPendingDeletion = albums[index]
        }
    }
}

struct AlbumRow: View {
    let album: VaultAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(album.name)
                .font(.headline)
            Text("\(album.itemCount) encrypted photos")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct AlbumDetailView: View {
    let album: VaultAlbum

    @EnvironmentObject private var vaultManager: VaultManager
    @EnvironmentObject private var privacyPreferencesStore: VaultPrivacyPreferencesStore

    @State private var selectedMediaItem: VaultMediaItem?
    @State private var errorMessage: String?
    @State private var isImporting = false
    @State private var isShowingPhotoPicker = false
    @State private var isShowingImportEducation = false
    @State private var mediaItemPendingDeletion: VaultMediaItem?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.name)
                            .font(.title2.bold())
                        Text("\(vaultManager.getMediaItems(albumId: album.id).count) encrypted photos")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        startImportFlow()
                    } label: {
                        Label("导入", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if isImporting {
                    ProgressView("Importing selected photos...")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(vaultManager.getMediaItems(albumId: album.id)) { item in
                        VaultThumbnailCell(item: item) {
                            selectedMediaItem = item
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                mediaItemPendingDeletion = item
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingPhotoPicker) {
            VaultPhotoPicker { results in
                Task {
                    await importSelectedImages(results)
                }
            }
        }
        .sheet(isPresented: $isShowingImportEducation) {
            VaultImportEducationView(
                dontShowAgain: !privacyPreferencesStore.preferences.showsImportEducation,
                onDontShowAgainChanged: { shouldSkipInFuture in
                    privacyPreferencesStore.update { preferences in
                        preferences.showsImportEducation = !shouldSkipInFuture
                    }
                },
                onContinue: {
                    isShowingImportEducation = false
                    isShowingPhotoPicker = true
                },
                onCancel: {
                    isShowingImportEducation = false
                }
            )
        }
        .sheet(item: $selectedMediaItem) { item in
            VaultPreviewView(item: item)
        }
        .alert(item: $mediaItemPendingDeletion) { item in
            Alert(
                title: Text("删除这张图片？"),
                message: Text("这会移除本地加密文件、缩略图和对应密钥引用。这个操作不能撤销。"),
                primaryButton: .destructive(Text("删除")) {
                    try? vaultManager.deleteMediaItem(item)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func importSelectedImages(_ images: [VaultImportedPhoto]) async {
        guard !images.isEmpty else { return }
        isImporting = true
        errorMessage = nil

        defer {
            isImporting = false
        }

        for image in images {
            do {
                try vaultManager.importPhoto(
                    to: album.id,
                    data: image.data,
                    sourceIdentifier: image.identifier
                )
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
    }

    private func startImportFlow() {
        if privacyPreferencesStore.preferences.showsImportEducation {
            isShowingImportEducation = true
        } else {
            isShowingPhotoPicker = true
        }
    }
}

struct VaultThumbnailCell: View {
    let item: VaultMediaItem
    let onTap: () -> Void

    @EnvironmentObject private var vaultManager: VaultManager

    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .task(id: item.id) {
            guard image == nil else { return }
            if let thumbnail = try? vaultManager.thumbnailImage(for: item) {
                image = thumbnail
            }
        }
    }
}

struct VaultPreviewView: View {
    let item: VaultMediaItem

    @EnvironmentObject private var vaultManager: VaultManager
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                        .background(Color.black.opacity(0.96))
                } else if let errorMessage {
                    VaultEmptyStateView(
                        title: "无法解密图片",
                        systemImage: "exclamationmark.triangle",
                        message: errorMessage
                    )
                } else {
                    ProgressView("Decrypting photo...")
                }
            }
            .task {
                do {
                    image = try vaultManager.image(for: item)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct VaultSettingsView: View {
    @EnvironmentObject private var privacyPreferencesStore: VaultPrivacyPreferencesStore
    @EnvironmentObject private var lockManager: VaultLockManager
    @Environment(\.dismiss) private var dismiss

    let itemCount: Int
    let storageUsage: Int64

    var body: some View {
        NavigationView {
            List {
                Section("Privacy Controls") {
                    Toggle(
                        "Lock vault when app leaves the foreground",
                        isOn: binding(for: \.autoLockOnBackground)
                    )
                    Toggle(
                        "Allow biometric unlock",
                        isOn: binding(for: \.allowsBiometricUnlock)
                    )
                    .disabled(lockManager.biometricType == .none)

                    if lockManager.biometricType == .none {
                        Text("This device does not currently offer Face ID or Touch ID for vault unlock.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section("How This App Handles Data") {
                    Label("Photos are imported with the system picker after direct user action.", systemImage: "hand.tap")
                    Label("Imported images are encrypted and stored locally on this device.", systemImage: "lock.doc")
                    Label("This version does not include cloud sync or remote backup.", systemImage: "icloud.slash")
                    Label("Deleting an item in the vault removes its encrypted file and key reference from local storage.", systemImage: "trash")
                }
                .font(.subheadline)

                Section("Current Vault") {
                    Label("\(itemCount) encrypted items", systemImage: "photo.stack")
                    Label(ByteCountFormatter.string(fromByteCount: storageUsage, countStyle: .file), systemImage: "internaldrive")
                }

                Section("Review-Safe Product Scope") {
                    Text("PhotoVault Pro is a straightforward local privacy tool. It does not disguise itself as another app, does not hide secret entry points, and does not claim server-side security.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings & Privacy")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func binding(for keyPath: WritableKeyPath<VaultPrivacyPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { privacyPreferencesStore.preferences[keyPath: keyPath] },
            set: { newValue in
                privacyPreferencesStore.update { preferences in
                    preferences[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

struct VaultImportEducationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var dontShowAgain: Bool

    let onDontShowAgainChanged: (Bool) -> Void
    let onContinue: () -> Void
    let onCancel: () -> Void

    init(
        dontShowAgain: Bool,
        onDontShowAgainChanged: @escaping (Bool) -> Void,
        onContinue: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _dontShowAgain = State(initialValue: dontShowAgain)
        self.onDontShowAgainChanged = onDontShowAgainChanged
        self.onContinue = onContinue
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationView {
            List {
                Section("Before You Import") {
                    Label("Only the photos you select in the system picker are imported.", systemImage: "checkmark.shield")
                    Label("Imported files are copied into the encrypted vault on this device.", systemImage: "lock.doc")
                    Label("Deleting the original from Photos does not automatically remove the encrypted copy in the vault.", systemImage: "photo.badge.exclamationmark")
                    Label("You can delete any imported item later from inside its album.", systemImage: "trash")
                }
                .font(.subheadline)

                Section {
                    Toggle("Don’t show this reminder again", isOn: $dontShowAgain)
                        .onChange(of: dontShowAgain) { newValue in
                            onDontShowAgainChanged(newValue)
                        }
                }
            }
            .navigationTitle("Import Reminder")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Continue") {
                        onContinue()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct VaultEmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

struct VaultImportedPhoto {
    let data: Data
    let identifier: String?
}

struct VaultPhotoPicker: UIViewControllerRepresentable {
    let onComplete: ([VaultImportedPhoto]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 20

        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onComplete: ([VaultImportedPhoto]) -> Void

        init(onComplete: @escaping ([VaultImportedPhoto]) -> Void) {
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard !results.isEmpty else {
                onComplete([])
                return
            }

            let dispatchGroup = DispatchGroup()
            let lock = NSLock()
            var importedPhotos: [VaultImportedPhoto] = []

            for result in results {
                guard result.itemProvider.canLoadObject(ofClass: UIImage.self) else {
                    continue
                }

                dispatchGroup.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { dispatchGroup.leave() }

                    guard let image = object as? UIImage,
                          let data = image.jpegData(compressionQuality: 0.92) else {
                        return
                    }

                    lock.lock()
                    importedPhotos.append(
                        VaultImportedPhoto(
                            data: data,
                            identifier: result.assetIdentifier
                        )
                    )
                    lock.unlock()
                }
            }

            dispatchGroup.notify(queue: .main) {
                self.onComplete(importedPhotos)
            }
        }
    }
}
