//
//  NativeMessagingManager.swift
//  Nook
//
//  Handles native messaging between web extensions and native application code
//  Phase 2.2: Native Messaging - Send Message
//  Phase 2.3: Native Messaging - Message Port
//

import Foundation
import WebKit

/// Protocol for native message handlers that can process messages from extensions
@available(macOS 15.5, *)
protocol NativeMessageHandler {
    /// Handle a message from an extension
    /// - Parameters:
    ///   - message: The message payload (must be JSON-serializable)
    ///   - applicationIdentifier: Optional application identifier specified by the extension
    ///   - extensionContext: The extension context that sent the message
    /// - Returns: A reply message (must be JSON-serializable) or nil if no reply
    /// - Throws: An error if message processing fails
    func handleMessage(
        _ message: Any,
        applicationIdentifier: String?,
        extensionContext: WKWebExtensionContext
    ) async throws -> Any?
}

/// Protocol for native message port handlers that manage persistent connections
@available(macOS 15.5, *)
protocol NativeMessagePortHandler {
    /// Handle a message received from the extension via a persistent port connection
    /// - Parameters:
    ///   - message: The message payload (must be JSON-serializable)
    ///   - connection: The connection object that can be used to send replies
    ///   - applicationIdentifier: Optional application identifier
    ///   - extensionContext: The extension context
    func handlePortMessage(
        _ message: Any,
        connection: MessagePortConnection,
        applicationIdentifier: String?,
        extensionContext: WKWebExtensionContext
    )
    
    /// Called when a port connection is established
    /// - Parameters:
    ///   - connection: The connection object
    ///   - applicationIdentifier: Optional application identifier
    ///   - extensionContext: The extension context
    func portDidConnect(
        _ connection: MessagePortConnection,
        applicationIdentifier: String?,
        extensionContext: WKWebExtensionContext
    )
    
    /// Called when a port connection is disconnected
    /// - Parameters:
    ///   - connection: The connection object
    ///   - applicationIdentifier: Optional application identifier
    ///   - extensionContext: The extension context
    ///   - error: Optional error indicating why the connection was disconnected
    func portDidDisconnect(
        _ connection: MessagePortConnection,
        applicationIdentifier: String?,
        extensionContext: WKWebExtensionContext,
        error: Error?
    )
}

/// Connection identifier for tracking message port connections
@available(macOS 15.5, *)
private struct ConnectionKey: Hashable {
    let extensionContextId: String
    let applicationIdentifier: String?
    
    init(extensionContext: WKWebExtensionContext, applicationIdentifier: String?) {
        self.extensionContextId = extensionContext.uniqueIdentifier
        self.applicationIdentifier = applicationIdentifier
    }
}

@available(macOS 15.5, *)
@MainActor
final class NativeMessagingManager {
    static let shared = NativeMessagingManager()
    
    /// Registered message handlers keyed by application identifier
    /// If applicationIdentifier is nil, messages are routed to the default handler
    private var handlers: [String?: NativeMessageHandler] = [:]
    
    /// Default handler for messages without a specific application identifier
    private var defaultHandler: NativeMessageHandler?
    
    /// Registered message port handlers keyed by application identifier
    private var portHandlers: [String?: NativeMessagePortHandler] = [:]
    
    /// Default port handler for connections without a specific application identifier
    private var defaultPortHandler: NativeMessagePortHandler?
    
    /// Active message port connections keyed by connection identifier
    private var connections: [ConnectionKey: MessagePortConnection] = [:]
    
    private init() {
        // Register a default logging handler for debugging
        // Apps can register their own handlers to override this
        registerHandler(LoggingNativeMessageHandler(), for: nil)
        registerPortHandler(LoggingNativeMessagePortHandler(), for: nil)
    }
    
    /// Register a message handler for a specific application identifier
    /// - Parameters:
    ///   - handler: The handler to register
    ///   - applicationIdentifier: The application identifier to handle, or nil for default handler
    func registerHandler(_ handler: NativeMessageHandler, for applicationIdentifier: String? = nil) {
        handlers[applicationIdentifier] = handler
        if applicationIdentifier == nil {
            defaultHandler = handler
        }
        print("📨 [NativeMessaging] Registered handler for identifier: \(applicationIdentifier ?? "default")")
    }
    
    /// Unregister a message handler
    /// - Parameter applicationIdentifier: The application identifier to unregister, or nil for default handler
    func unregisterHandler(for applicationIdentifier: String? = nil) {
        handlers.removeValue(forKey: applicationIdentifier)
        if applicationIdentifier == nil {
            defaultHandler = nil
        }
        print("📨 [NativeMessaging] Unregistered handler for identifier: \(applicationIdentifier ?? "default")")
    }
    
    /// Process a message from an extension
    /// - Parameters:
    ///   - message: The message payload
    ///   - applicationIdentifier: Optional application identifier
    ///   - extensionContext: The extension context
    /// - Returns: A reply message or nil
    /// - Throws: An error if processing fails
    func processMessage(
        _ message: Any,
        applicationIdentifier: String?,
        extensionContext: WKWebExtensionContext
    ) async throws -> Any? {
        // Validate message is JSON-serializable
        guard JSONSerialization.isValidJSONObject(message) else {
            throw NativeMessagingError.invalidMessage("Message must be JSON-serializable")
        }
        
        // Find appropriate handler
        let handler: NativeMessageHandler?
        if let identifier = applicationIdentifier {
            handler = handlers[identifier] ?? handlers[nil] ?? defaultHandler
        } else {
            handler = handlers[nil] ?? defaultHandler
        }
        
        guard let handler = handler else {
            // No handler registered - this is expected for extensions without native handlers
            // Per Apple docs: "no action is performed if not implemented"
            print("⚠️ [NativeMessaging] No handler registered for identifier: \(applicationIdentifier ?? "nil")")
            print("   Returning nil (no action performed)")
            return nil
        }
        
        // Process message
        do {
            let reply = try await handler.handleMessage(
                message,
                applicationIdentifier: applicationIdentifier,
                extensionContext: extensionContext
            )
            return reply
        } catch {
            print("❌ [NativeMessaging] Handler error: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Message Port Connection Management (Phase 2.3)
    
    /// Register a message port handler for a specific application identifier
    /// - Parameters:
    ///   - handler: The handler to register
    ///   - applicationIdentifier: The application identifier to handle, or nil for default handler
    func registerPortHandler(_ handler: NativeMessagePortHandler, for applicationIdentifier: String? = nil) {
        portHandlers[applicationIdentifier] = handler
        if applicationIdentifier == nil {
            defaultPortHandler = handler
        }
        print("🔌 [NativeMessaging] Registered port handler for identifier: \(applicationIdentifier ?? "default")")
    }
    
    /// Unregister a message port handler
    /// - Parameter applicationIdentifier: The application identifier to unregister, or nil for default handler
    func unregisterPortHandler(for applicationIdentifier: String? = nil) {
        portHandlers.removeValue(forKey: applicationIdentifier)
        if applicationIdentifier == nil {
            defaultPortHandler = nil
        }
        print("🔌 [NativeMessaging] Unregistered port handler for identifier: \(applicationIdentifier ?? "default")")
    }
    
    /// Create a new message port connection
    /// - Parameters:
    ///   - port: The WKWebExtensionMessagePort to wrap
    ///   - extensionContext: The extension context
    ///   - applicationIdentifier: Optional application identifier
    /// - Returns: A MessagePortConnection object
    func createConnection(
        port: WKWebExtension.MessagePort,
        extensionContext: WKWebExtensionContext,
        applicationIdentifier: String?
    ) -> MessagePortConnection {
        let key = ConnectionKey(extensionContext: extensionContext, applicationIdentifier: applicationIdentifier)
        
        // If connection already exists, return it
        if let existing = connections[key] {
            print("⚠️ [NativeMessaging] Connection already exists for key: \(key)")
            return existing
        }
        
        // Create new connection
        let connection = MessagePortConnection(
            port: port,
            extensionContext: extensionContext,
            applicationIdentifier: applicationIdentifier,
            manager: self
        )
        
        connections[key] = connection
        print("✅ [NativeMessaging] Created new connection for identifier: \(applicationIdentifier ?? "nil")")
        
        return connection
    }
    
    /// Remove a connection when it's disconnected
    /// - Parameter connection: The connection to remove
    func removeConnection(_ connection: MessagePortConnection) {
        let key = ConnectionKey(
            extensionContext: connection.extensionContext,
            applicationIdentifier: connection.applicationIdentifier
        )
        connections.removeValue(forKey: key)
        print("🔌 [NativeMessaging] Removed connection for identifier: \(connection.applicationIdentifier ?? "nil")")
    }
    
    /// Get the appropriate port handler for an application identifier
    /// - Parameter applicationIdentifier: The application identifier, or nil
    /// - Returns: The port handler, or nil if none registered
    func getPortHandler(for applicationIdentifier: String?) -> NativeMessagePortHandler? {
        if let identifier = applicationIdentifier {
            return portHandlers[identifier] ?? portHandlers[nil] ?? defaultPortHandler
        } else {
            return portHandlers[nil] ?? defaultPortHandler
        }
    }
    
    // MARK: - Phase 7.1: Connection Query Methods
    
    /// Get all active connections
    func getAllConnections() -> [MessagePortConnection] {
        return Array(connections.values)
    }
    
    /// Get connections for a specific extension context
    func getConnections(for extensionContext: WKWebExtensionContext) -> [MessagePortConnection] {
        return connections.values.filter { $0.extensionContext.uniqueIdentifier == extensionContext.uniqueIdentifier }
    }
    
    /// Get connections for a specific application identifier
    func getConnections(for applicationIdentifier: String?) -> [MessagePortConnection] {
        return connections.values.filter { $0.applicationIdentifier == applicationIdentifier }
    }
    
    /// Get a specific connection by extension context and application identifier
    func getConnection(
        for extensionContext: WKWebExtensionContext,
        applicationIdentifier: String?
    ) -> MessagePortConnection? {
        let key = ConnectionKey(extensionContext: extensionContext, applicationIdentifier: applicationIdentifier)
        return connections[key]
    }
    
    /// Validate all connections and remove stale ones
    func validateAllConnections() {
        let staleConnections = connections.values.filter { !$0.isValid() }
        for connection in staleConnections {
            removeConnection(connection)
        }
    }
}

/// Errors that can occur during native messaging
@available(macOS 15.5, *)
enum NativeMessagingError: LocalizedError {
    case invalidMessage(String)
    case noHandler(String)
    case serializationFailed(String)
    case handlerError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidMessage(let message):
            return "Invalid message: \(message)"
        case .noHandler(let message):
            return "No handler: \(message)"
        case .serializationFailed(let message):
            return "Serialization failed: \(message)"
        case .handlerError(let message):
            return "Handler error: \(message)"
        }
    }
}

/// Default logging handler for debugging native messages
/// This handler logs all messages and returns a simple acknowledgment
@available(macOS 15.5, *)
final class LoggingNativeMessageHandler: NativeMessageHandler {
    func handleMessage(
        _ message: Any,
        applicationIdentifier: String?,
        extensionContext: WKWebExtensionContext
    ) async throws -> Any? {
        let extensionName = extensionContext.webExtension.displayName ?? "Unknown"
        print("📨 [LoggingHandler] Received message from '\(extensionName)'")
        print("   Application ID: \(applicationIdentifier ?? "nil")")
        print("   Message: \(message)")
        
        // Return a simple acknowledgment
        return [
            "status": "received",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }
}

/// Connection state for message port connections
@available(macOS 15.5, *)
enum ConnectionState {
    case connected
    case disconnecting
    case disconnected
}

/// Connection metadata for tracking connection health and statistics
@available(macOS 15.5, *)
struct ConnectionMetadata {
    let creationTime: Date
    var lastMessageTime: Date?
    var messageCount: Int = 0
    var errorCount: Int = 0
    var lastError: Error?
    
    init() {
        self.creationTime = Date()
    }
}

/// Disconnection reason for tracking why connections were closed
@available(macOS 15.5, *)
enum DisconnectionReason {
    case userInitiated
    case error(Error)
    case timeout
    case portInvalid
    
    var description: String {
        switch self {
        case .userInitiated:
            return "user initiated"
        case .error(let error):
            return "error: \(error.localizedDescription)"
        case .timeout:
            return "timeout"
        case .portInvalid:
            return "port invalid"
        }
    }
}

/// Wrapper class for WKWebExtensionMessagePort that manages connection lifecycle
@available(macOS 15.5, *)
@MainActor
final class MessagePortConnection {
    let port: WKWebExtension.MessagePort
    let extensionContext: WKWebExtensionContext
    let applicationIdentifier: String?
    private weak var manager: NativeMessagingManager?
    
    // Phase 7.1: Connection state tracking
    private(set) var state: ConnectionState = .connected {
        didSet {
            if oldValue != state {
                print("🔌 [MessagePort] State changed: \(oldValue) -> \(state)")
            }
        }
    }
    
    // Phase 7.1: Connection metadata
    private(set) var metadata = ConnectionMetadata()
    
    // Phase 7.1: Disconnection reason
    private(set) var disconnectionReason: DisconnectionReason?
    
    // Phase 7.1: Connection timeout (default 5 minutes of inactivity)
    private let connectionTimeout: TimeInterval = 300 // 5 minutes
    private var healthCheckTimer: Timer?
    
    init(
        port: WKWebExtension.MessagePort,
        extensionContext: WKWebExtensionContext,
        applicationIdentifier: String?,
        manager: NativeMessagingManager
    ) {
        self.port = port
        self.extensionContext = extensionContext
        self.applicationIdentifier = applicationIdentifier
        self.manager = manager
        self.state = .connected
        
        // Phase 7.1: Start health monitoring
        startHealthMonitoring()
        
        // Set up message handler to forward messages to native handlers
        port.messageHandler = { [weak self] message, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ [MessagePort] Error receiving message: \(error.localizedDescription)")
                return
            }
            
            guard let message = message else {
                print("⚠️ [MessagePort] Received nil message")
                return
            }
            
            // Forward to handler
            Task { @MainActor in
                await self.handleIncomingMessage(message)
            }
        }
        
        // Set up disconnect handler
        port.disconnectHandler = { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ [MessagePort] Disconnected with error: \(error.localizedDescription)")
            } else {
                print("🔌 [MessagePort] Disconnected normally")
            }
            
            // Notify handler
            Task { @MainActor in
                await self.handleDisconnection(error: error)
            }
        }
        
        // Phase 7.1: Notify handler of connection
        Task { @MainActor in
            await self.notifyConnectionEstablished()
        }
    }
    
    deinit {
        // Phase 7.1: Stop health monitoring
        // Timer invalidation can be done from any thread, so we can do it directly
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }
    
    // MARK: - Phase 7.1: Connection State Management
    
    /// Check if the connection is still valid
    func isValid() -> Bool {
        guard state == .connected else { return false }
        guard !port.isDisconnected else {
            // Port is disconnected but we haven't updated state yet
            state = .disconnected
            return false
        }
        return true
    }
    
    /// Validate connection health
    func validateConnection() -> Bool {
        guard isValid() else { return false }
        
        // Check for timeout
        if let lastMessageTime = metadata.lastMessageTime {
            let timeSinceLastMessage = Date().timeIntervalSince(lastMessageTime)
            if timeSinceLastMessage > connectionTimeout {
                print("⚠️ [MessagePort] Connection timeout: \(timeSinceLastMessage)s since last message")
                disconnect(reason: .timeout)
                return false
            }
        } else {
            // No messages yet, check creation time
            let timeSinceCreation = Date().timeIntervalSince(metadata.creationTime)
            if timeSinceCreation > connectionTimeout {
                print("⚠️ [MessagePort] Connection timeout: \(timeSinceCreation)s since creation")
                disconnect(reason: .timeout)
                return false
            }
        }
        
        return true
    }
    
    // MARK: - Phase 7.1: Health Monitoring
    
    private func startHealthMonitoring() {
        // Check connection health every 30 seconds
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                _ = self.validateConnection()
            }
        }
    }
    
    private func stopHealthMonitoring() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }
    
    // MARK: - Phase 7.1: Connection Metadata
    
    /// Update metadata when a message is sent or received
    func recordMessage() {
        metadata.lastMessageTime = Date()
        metadata.messageCount += 1
    }
    
    /// Record an error in metadata
    func recordError(_ error: Error) {
        metadata.errorCount += 1
        metadata.lastError = error
    }
    
    /// Get connection age
    func connectionAge() -> TimeInterval {
        return Date().timeIntervalSince(metadata.creationTime)
    }
    
    /// Get time since last message
    func timeSinceLastMessage() -> TimeInterval? {
        guard let lastMessageTime = metadata.lastMessageTime else { return nil }
        return Date().timeIntervalSince(lastMessageTime)
    }
    
    // MARK: - Phase 7.1: Connection Notification
    
    private func notifyConnectionEstablished() async {
        guard let manager = manager else { return }
        
        // Notify handler of connection
        if let handler = manager.getPortHandler(for: applicationIdentifier) {
            handler.portDidConnect(
                self,
                applicationIdentifier: applicationIdentifier,
                extensionContext: extensionContext
            )
        }
    }
    
    // Phase 7.2: Message queue for pending messages
    private var messageQueue: [(message: Any, completionHandler: ((Error?) -> Void)?, retryCount: Int)] = []
    private var isSendingMessage = false
    private let maxRetryCount = 3
    private let retryDelay: TimeInterval = 1.0
    
    /// Send a message to the extension via this port
    /// - Parameters:
    ///   - message: The message to send (must be JSON-serializable)
    ///   - completionHandler: Called when the message is sent or an error occurs
    func sendMessage(_ message: Any?, completionHandler: ((Error?) -> Void)? = nil) {
        // Phase 7.2: Validate connection state
        guard state == .connected else {
            let error = NSError(
                domain: "MessagePortConnection",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Port is not connected (state: \(state))"]
            )
            completionHandler?(error)
            return
        }
        
        guard !port.isDisconnected else {
            state = .disconnected
            let error = NSError(
                domain: "MessagePortConnection",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Port is disconnected"]
            )
            completionHandler?(error)
            return
        }
        
        // Phase 7.2: Validate message is JSON-serializable
        guard let message = message else {
            // Nil message is allowed (represents empty message)
            sendMessageInternal(message, completionHandler: completionHandler)
            return
        }
        
        guard JSONSerialization.isValidJSONObject(message) else {
            let error = NativeMessagingError.serializationFailed("Message must be JSON-serializable")
            recordError(error)
            completionHandler?(error)
            return
        }
        
        // Phase 7.2: Queue message if another send is in progress
        if isSendingMessage {
            messageQueue.append((message: message, completionHandler: completionHandler, retryCount: 0))
            print("📬 [MessagePort] Queued message (queue size: \(messageQueue.count))")
            return
        }
        
        sendMessageInternal(message, completionHandler: completionHandler)
    }
    
    /// Internal method to send a message (with retry logic)
    private func sendMessageInternal(_ message: Any?, completionHandler: ((Error?) -> Void)?, retryCount: Int = 0) {
        guard state == .connected && !port.isDisconnected else {
            let error = NSError(
                domain: "MessagePortConnection",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Port is disconnected"]
            )
            completionHandler?(error)
            processNextQueuedMessage()
            return
        }
        
        isSendingMessage = true
        
        port.sendMessage(message) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                self.recordError(error)
                print("❌ [MessagePort] Error sending message: \(error.localizedDescription)")
                
                // Phase 7.2: Retry logic
                if retryCount < self.maxRetryCount && self.state == .connected {
                    print("🔄 [MessagePort] Retrying message (attempt \(retryCount + 1)/\(self.maxRetryCount))")
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(self.retryDelay * 1_000_000_000))
                        self.sendMessageInternal(message, completionHandler: completionHandler, retryCount: retryCount + 1)
                    }
                    return
                } else {
                    completionHandler?(error)
                }
            } else {
                // Phase 7.2: Record successful message
                self.recordMessage()
                print("✅ [MessagePort] Message sent successfully")
                completionHandler?(nil)
            }
            
            self.isSendingMessage = false
            self.processNextQueuedMessage()
        }
    }
    
    /// Process the next queued message
    private func processNextQueuedMessage() {
        guard !messageQueue.isEmpty else { return }
        
        let next = messageQueue.removeFirst()
        sendMessageInternal(next.message, completionHandler: next.completionHandler, retryCount: next.retryCount)
    }
    
    /// Disconnect the port
    /// - Parameter error: Optional error to include in disconnection
    func disconnect(error: Error? = nil) {
        // Phase 7.3: Handle double disconnect
        guard state == .connected else {
            print("⚠️ [MessagePort] Already disconnected or disconnecting (state: \(state))")
            return
        }
        
        state = .disconnecting
        stopHealthMonitoring()
        
        // Phase 7.3: Cancel any pending message sends
        cancelPendingMessages()
        
        if let error = error {
            disconnectionReason = .error(error)
            port.disconnect(throwing: error)
        } else {
            disconnectionReason = .userInitiated
            port.disconnect()
        }
    }
    
    /// Cancel all pending messages in the queue
    private func cancelPendingMessages() {
        guard !messageQueue.isEmpty else { return }
        
        let error = NSError(
            domain: "MessagePortConnection",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Connection disconnected"]
        )
        
        let count = messageQueue.count
        for queuedMessage in messageQueue {
            queuedMessage.completionHandler?(error)
        }
        
        messageQueue.removeAll()
        isSendingMessage = false
        print("📬 [MessagePort] Cancelled \(count) pending messages")
    }
    
    /// Disconnect with a specific reason
    func disconnect(reason: DisconnectionReason) {
        switch reason {
        case .userInitiated:
            disconnect(error: nil)
        case .error(let error):
            disconnect(error: error)
        case .timeout:
            let timeoutError = NSError(
                domain: "MessagePortConnection",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Connection timeout"]
            )
            disconnect(error: timeoutError)
        case .portInvalid:
            let invalidError = NSError(
                domain: "MessagePortConnection",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Port is invalid"]
            )
            disconnect(error: invalidError)
        }
    }
    
    /// Handle an incoming message from the extension
    private func handleIncomingMessage(_ message: Any) async {
        // Phase 7.2: Validate connection state
        guard state == .connected else {
            print("⚠️ [MessagePort] Received message but connection is not in connected state: \(state)")
            return
        }
        
        // Phase 7.2: Validate message is JSON-serializable (for logging/debugging)
        if !JSONSerialization.isValidJSONObject(message) {
            let error = NativeMessagingError.invalidMessage("Received message is not JSON-serializable")
            recordError(error)
            print("❌ [MessagePort] Invalid message received: \(error.localizedDescription)")
            return
        }
        
        // Phase 7.2: Record message reception
        recordMessage()
        
        guard let manager = manager else { return }
        
        // Get appropriate handler
        guard let handler = manager.getPortHandler(for: applicationIdentifier) else {
            print("⚠️ [MessagePort] No handler registered for identifier: \(applicationIdentifier ?? "nil")")
            return
        }
        
        // Phase 7.2: Forward to handler with error handling
        do {
            handler.handlePortMessage(
                message,
                connection: self,
                applicationIdentifier: applicationIdentifier,
                extensionContext: extensionContext
            )
        } catch {
            let handlerError = NativeMessagingError.handlerError("Handler threw error: \(error.localizedDescription)")
            recordError(handlerError)
            print("❌ [MessagePort] Handler error: \(error.localizedDescription)")
        }
    }
    
    /// Handle port disconnection
    private func handleDisconnection(error: Error?) async {
        // Phase 7.3: Prevent double disconnection handling
        guard state != .disconnected else {
            print("⚠️ [MessagePort] Disconnection already handled")
            return
        }
        
        guard let manager = manager else { return }
        
        // Phase 7.3: Update state atomically
        state = .disconnected
        
        // Phase 7.3: Stop health monitoring if still running
        stopHealthMonitoring()
        
        // Phase 7.3: Cancel any pending messages
        cancelPendingMessages()
        
        // Phase 7.1: Record disconnection reason if not already set
        if disconnectionReason == nil {
            if let error = error {
                disconnectionReason = .error(error)
            } else {
                disconnectionReason = .userInitiated
            }
        }
        
        // Phase 7.3: Record error in metadata if present
        if let error = error {
            recordError(error)
        }
        
        // Phase 7.3: Clean up message handlers
        port.messageHandler = nil
        port.disconnectHandler = nil
        
        // Phase 7.3: Notify handler with proper error context
        if let handler = manager.getPortHandler(for: applicationIdentifier) {
            handler.portDidDisconnect(
                self,
                applicationIdentifier: applicationIdentifier,
                extensionContext: extensionContext,
                error: error
            )
        }
        
        // Phase 7.3: Remove from manager's connection dictionary atomically
        manager.removeConnection(self)
        
        print("🔌 [MessagePort] Disconnection complete (reason: \(disconnectionReason?.description ?? "unknown"))")
    }
}

/// Default logging handler for debugging message port connections
@available(macOS 15.5, *)
final class LoggingNativeMessagePortHandler: NativeMessagePortHandler {
    func handlePortMessage(
        _ message: Any,
        connection: MessagePortConnection,
        applicationIdentifier: String?,
        extensionContext: WKWebExtensionContext
    ) {
        let extensionName = extensionContext.webExtension.displayName ?? "Unknown"
        print("📨 [LoggingPortHandler] Received port message from '\(extensionName)'")
        print("   Application ID: \(applicationIdentifier ?? "nil")")
        print("   Message: \(message)")
        
        // Send acknowledgment back
        let ack = [
            "status": "received",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        Task { @MainActor in
            connection.sendMessage(ack)
        }
    }
    
    func portDidConnect(
        _ connection: MessagePortConnection,
        applicationIdentifier: String?,
        extensionContext: WKWebExtensionContext
    ) {
        let extensionName = extensionContext.webExtension.displayName ?? "Unknown"
        print("🔌 [LoggingPortHandler] Port connected for '\(extensionName)'")
        print("   Application ID: \(applicationIdentifier ?? "nil")")
    }
    
    func portDidDisconnect(
        _ connection: MessagePortConnection,
        applicationIdentifier: String?,
        extensionContext: WKWebExtensionContext,
        error: Error?
    ) {
        let extensionName = extensionContext.webExtension.displayName ?? "Unknown"
        if let error = error {
            print("❌ [LoggingPortHandler] Port disconnected for '\(extensionName)' with error: \(error.localizedDescription)")
        } else {
            print("🔌 [LoggingPortHandler] Port disconnected for '\(extensionName)'")
        }
    }
}

