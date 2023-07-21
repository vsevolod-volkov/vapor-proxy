//
//  VaporProxyAppPool.swift
//  
//
//  Created by Vsevolod Volkov on 17.07.2023.
//

import Foundation
import Vapor

extension Proxy {
    public struct ProxyApplicationConfiguration {
        public var root: String
        public var configuration: Configuration
        public var mainApplication: Application?
        
        public static let `default` = ProxyApplicationConfiguration()
        
        public init(root: String = "/", configuration: Configuration = .default, mainApplication: Application? = nil) {
            self.root = root
            self.configuration = configuration
            self.mainApplication = mainApplication
        }
    }
    
    public final class Pool {
        public typealias Port = Int
        
        private var applications: [Port: Application]
        
        public init() {
            self.applications = [:]
        }
        
        deinit {
            applications.keys.forEach { self.unregister(port: $0) }
        }
    }
}


extension Proxy.Pool {
    public enum ProxyPoolError: Error {
        case portIsBusy
    }
    
    public func register(port: Port, targetURL: URL, configuration: Proxy.ProxyApplicationConfiguration = .default) throws {
        guard !self.applications.keys.contains(port) else {
            throw ProxyPoolError.portIsBusy
        }
        
        self.applications[port] = try Proxy.application(
            listeningOn: port,
            passPathsUnder: configuration.root,
            to: targetURL,
            configuration: configuration.configuration,
            takeDefaultsFrom: configuration.mainApplication,
            start: true
        )
    }
    
    public func register<P>(ports: P, producingTargetURLWith targetURL: (Port) -> URL, configuration: Proxy.ProxyApplicationConfiguration = .default, mapConfigurationWith mapper: ((Port, Proxy.ProxyApplicationConfiguration) throws -> Proxy.ProxyApplicationConfiguration)? = nil) throws where P: Sequence, P.Element == Port {
        try ports.forEach { try self.register(
            port: $0,
            targetURL: targetURL($0),
            configuration: mapper?($0, configuration) ?? configuration
        )}
    }
    
    @discardableResult
    public func unregister(port: Port, shutdown: Bool = true) -> Application? {
        if shutdown, let application = self.applications[port] {
            application.shutdown()
        }
        return self.applications.removeValue(forKey: port)
    }
}
