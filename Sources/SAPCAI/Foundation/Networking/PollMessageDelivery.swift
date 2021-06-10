import Combine
import Foundation
import SAPCommon

/// Handles Long Polling mechanism to CAI Channel Connector to load messages
public class PollMessageDelivery: MessageDelivering {
    public var onMessages: ((Result<CAIConversationResultData, CAIError>) -> Void)?

    public var channelToken: String?

    public var channelId: String
        
    public var lastMessageId: String?
    
    private var serviceConfig: CAIServiceConfig
    
    private var requestQueue: OperationQueue = {
        let ret = OperationQueue()
        // serial queue since we want the poll endpoint to be called only at once
        ret.maxConcurrentOperationCount = 1
        ret.qualityOfService = .userInteractive
        return ret
    }()
    
    private var conversationId: String?

    private var state: State = .stopped

    private var logger = Logger.shared(named: "PollMessageDelivery")
    
    enum State {
        case stopped
        case running
    }
    
    /// Constructor
    ///
    /// - Parameters:
    ///   - channelId: String
    ///   - serviceConfig: CAIServiceConfig
    public init(channelToken: String?, channelId: String, serviceConfig: CAIServiceConfig) {
        self.channelToken = channelToken
        self.channelId = channelId
        self.serviceConfig = serviceConfig
    }
    
    deinit {
        print("poll deinit")
    }
    
    /// Start pollinh. Always return a publisher that emits true, never fails.
    public func reconnect() -> AnyPublisher<Bool, CAIError> {
        self.start()
        return Result.success(true).publisher.eraseToAnyPublisher()
    }
    
    public func initialize(_ conversationId: String) {
        self.conversationId = conversationId
    }
    
    public func stop() {
        self.requestQueue.cancelAllOperations()
        self.state = .stopped
    }
    
    public func start() {
        let typingMsg = CAIConversationResultData.isTyping
        self.onMessages?(.success(typingMsg))
        
        self.startPolling()
    }
    
    private func startPolling() {
        // cancel current operation
        self.stop()
        
        // run
        self.state = .running
        let request = CAILoadConversationRequest(channelId: channelId, channelToken: channelToken, conversationId: conversationId!, lastMessageId: lastMessageId)
        let operation = CAILoadConversationOperation(self.serviceConfig, request: request) { [weak self] result in

            guard let self = self else { return }

            switch result {
            case .success(let data):
                let mapped = result.map { $0.results! }
                
                self.onMessages?(mapped)

                // stop polling in case the server returns a wait time different than 0
                if let waitTime = data.results?.waitTime, waitTime == 0 {
                    self.startPolling()
                } else {
                    self.stop()
                }
            case .failure(let error):
                switch error.type {
                case .server:
                    self.logger.error(error.debugDescription, error: error)
                    self.onMessages?(.failure(error))
                    self.startPolling()
                case .cancelled:
                    () // this naturally occurs when bot responses early?
                case .dataDecoding, .conversationNotFound:
                    self.logger.error(error.debugDescription, error: error)
                    self.onMessages?(.failure(error))
                    self.stop()
                }
            }
        }
        self.requestQueue.addOperation(operation)
    }
}