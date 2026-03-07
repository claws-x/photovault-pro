//
//  FaceIDAuthenticationManager.swift
//  PhotoVault Pro
//
//  Face ID 认证管理器 - 处理生物识别认证的核心类
//

import Foundation
import LocalAuthentication
import Combine
import UIKit

// MARK: - 认证错误类型

enum AuthenticationError: LocalizedError {
    case biometryNotAvailable
    case biometryLockedOut
    case userCancel
    case userFallback
    case systemCancel
    case passcodeNotSet
    case unknown(OSStatus)
    
    var errorDescription: String? {
        switch self {
        case .biometryNotAvailable:
            return "Face ID 不可用，请使用密码"
        case .biometryLockedOut:
            return "Face ID 已锁定，请使用密码"
        case .userCancel:
            return "用户取消认证"
        case .userFallback:
            return "用户使用密码认证"
        case .systemCancel:
            return "认证被系统取消"
        case .passcodeNotSet:
            return "设备未设置密码"
        case .unknown(let status):
            return "认证错误：\(status)"
        }
    }
}

// MARK: - 认证结果

struct AuthenticationResult {
    let success: Bool
    let method: AuthenticationMethod
    let timestamp: Date
    
    enum AuthenticationMethod {
        case faceID
        case touchID
        case passcode
        case emergencyPasscode  // 伪装模式紧急密码
    }
}

// MARK: - 认证配置

struct AuthenticationConfig {
    /// 允许的最大失败次数
    let maxFailedAttempts: Int = 5
    /// 失败后的锁定时间 (秒)
    let lockoutDuration: TimeInterval = 30
    /// 是否启用紧急擦除
    let enableEmergencyWipe: Bool = true
    /// 触发紧急擦除的失败次数
    let emergencyWipeThreshold: Int = 10
    /// 后台返回后需要认证的超时 (秒)，0 表示立即
    let backgroundTimeout: TimeInterval = 0
}

// MARK: - Face ID 认证管理器

final class FaceIDAuthenticationManager: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = FaceIDAuthenticationManager()
    
    // MARK: - Properties
    
    private let context = LAContext()
    private let config = AuthenticationConfig()
    
    @Published private(set) var isLocked = true
    @Published private(set) var failedAttempts = 0
    @Published private(set) var isBiometryAvailable = false
    @Published private(set) var biometryType: LABiometryType = .none
    
    private var lockoutTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    // 认证状态回调
    private var authCompletionHandler: ((Result<AuthenticationResult, Error>) -> Void)?
    
    // MARK: - 初始化
    
    private init() {
        checkBiometryAvailability()
        setupNotifications()
    }
    
    // MARK: - 生物识别检测
    
    /// 检查生物识别可用性
    func checkBiometryAvailability() {
        let localContext = LAContext()
        var error: NSError?
        
        // iOS 26 兼容：直接使用 rawValue 1 = biometry
        if localContext.canEvaluatePolicy(LAPolicy(rawValue: 1)!, error: &error) {
            self.isBiometryAvailable = true
            self.biometryType = localContext.biometryType
            
            switch self.biometryType {
            case .faceID:
                NSLog("Face ID 可用")
            case .touchID:
                NSLog("Touch ID 可用")
            case .none:
                self.isBiometryAvailable = false
                NSLog("无生物识别功能")
            @unknown default:
                self.isBiometryAvailable = false
                NSLog("未知生物识别类型")
            }
        } else {
            self.isBiometryAvailable = false
            self.biometryType = .none
            NSLog("生物识别不可用：\(error?.localizedDescription ?? "未知错误")")
        }
    }
    
    // MARK: - 认证方法
    
    /// 执行 Face ID 认证
    /// - Parameters:
    ///   - reason: 认证原因说明
    ///   - allowFallback: 是否允许密码回退
    ///   - completion: 认证结果回调
    func authenticate(
        reason: String = "需要验证您的身份以访问 PhotoVault",
        allowFallback: Bool = true,
        completion: @escaping (Result<AuthenticationResult, Error>) -> Void
    ) {
        // 检查是否处于锁定状态
        if isLocked && lockoutTimer != nil {
            completion(.failure(AuthenticationError.biometryLockedOut))
            return
        }
        
        // 检查生物识别可用性
        guard isBiometryAvailable else {
            if allowFallback {
                requestPasscode(reason: reason, completion: completion)
            } else {
                completion(.failure(AuthenticationError.biometryNotAvailable))
            }
            return
        }
        
        let localContext = LAContext()
        localContext.localizedReason = reason
        localContext.localizedCancelTitle = "取消"
        
        if allowFallback {
            localContext.localizedFallbackTitle = "使用密码"
        }
        
        // 评估生物识别策略 (iOS 26: rawValue 1 = biometry)
        localContext.evaluatePolicy(LAPolicy(rawValue: 1)!, localizedReason: reason) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.handleAuthenticationResult(
                    success: success,
                    error: error,
                    method: self?.biometryType == .faceID ? .faceID : .touchID,
                    completion: completion
                )
            }
        }
    }
    
    /// 请求密码认证
    private func requestPasscode(
        reason: String,
        completion: @escaping (Result<AuthenticationResult, Error>) -> Void
    ) {
        let localContext = LAContext()
        
        // iOS 26: rawValue 2 = passcode
        localContext.evaluatePolicy(LAPolicy(rawValue: 2)!, localizedReason: reason) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.handleAuthenticationResult(
                    success: success,
                    error: error,
                    method: .passcode,
                    completion: completion
                )
            }
        }
    }
    
    // MARK: - 认证结果处理
    
    private func handleAuthenticationResult(
        success: Bool,
        error: Error?,
        method: AuthenticationResult.AuthenticationMethod,
        completion: @escaping (Result<AuthenticationResult, Error>) -> Void
    ) {
        if success {
            // 认证成功
            resetFailedAttempts()
            unlock()
            let result = AuthenticationResult(
                success: true,
                method: method,
                timestamp: Date()
            )
            completion(.success(result))
        } else {
            // 认证失败
            handleAuthenticationError(error: error, completion: completion)
        }
    }
    
    private func handleAuthenticationError(
        error: Error?,
        completion: @escaping (Result<AuthenticationResult, Error>) -> Void
    ) {
        guard let laError = error as? LAError else {
            completion(.failure(AuthenticationError.unknown(-1)))
            return
        }
        
        switch laError.code {
        case .userCancel:
            completion(.failure(AuthenticationError.userCancel))
            
        case .userFallback:
            // 用户选择使用密码
            requestPasscode(reason: "需要验证您的身份以访问 PhotoVault") { result in
                completion(result)
            }
            
        case .systemCancel:
            completion(.failure(AuthenticationError.systemCancel))
            
        case .passcodeNotSet:
            completion(.failure(AuthenticationError.passcodeNotSet))
            
        case .biometryNotAvailable:
            // 尝试密码回退
            requestPasscode(reason: "需要验证您的身份以访问 PhotoVault") { result in
                completion(result)
            }
            
        case .biometryNotEnrolled:
            completion(.failure(AuthenticationError.biometryNotAvailable))
            
        case .biometryLockout:
            incrementFailedAttempts()
            completion(.failure(AuthenticationError.biometryLockedOut))
            
        default:
            incrementFailedAttempts()
            completion(.failure(laError))
        }
    }
    
    // MARK: - 失败次数管理
    
    private func incrementFailedAttempts() {
        failedAttempts += 1
        
        if failedAttempts >= config.maxFailedAttempts {
            startLockoutTimer()
        }
        
        if config.enableEmergencyWipe && 
           failedAttempts >= config.emergencyWipeThreshold {
            triggerEmergencyWipe()
        }
    }
    
    private func resetFailedAttempts() {
        failedAttempts = 0
        stopLockoutTimer()
    }
    
    private func startLockoutTimer() {
        stopLockoutTimer()
        
        lockoutTimer = Timer.scheduledTimer(
            withTimeInterval: config.lockoutDuration,
            repeats: false
        ) { [weak self] _ in
            self?.resetFailedAttempts()
        }
    }
    
    private func stopLockoutTimer() {
        lockoutTimer?.invalidate()
        lockoutTimer = nil
    }
    
    // MARK: - 锁定状态管理
    
    func lock() {
        isLocked = true
        resetFailedAttempts()
    }
    
    func unlock() {
        isLocked = false
        resetFailedAttempts()
    }
    
    // MARK: - 紧急擦除
    
    private func triggerEmergencyWipe() {
        NSLog("⚠️ 触发紧急数据擦除")
        // 通知数据管理器执行安全擦除
        NotificationCenter.default.post(
            name: .emergencyWipeTriggered,
            object: nil
        )
    }
    
    // MARK: - 通知监听
    
    private func setupNotifications() {
        // 监听应用进入后台
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                // 应用进入后台时锁定
                self?.lock()
            }
            .store(in: &cancellables)
        
        // 监听设备锁定
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.lock()
            }
            .store(in: &cancellables)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let emergencyWipeTriggered = Notification.Name("emergencyWipeTriggered")
}

// MARK: - LAContext Extension

// 注意：iOS 11.0+ 原生支持 biometryType 属性，不需要扩展
// 此扩展已移除，避免无限递归
