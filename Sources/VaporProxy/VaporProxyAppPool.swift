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
        
        internal var applications: [Port: ProxyApplication]
        
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
    
    @discardableResult
    public func register(port: Port, targetURL: URL, configuration: Proxy.ProxyApplicationConfiguration = .default) throws -> Application {
        guard !self.applications.keys.contains(port) else {
            throw ProxyPoolError.portIsBusy
        }
        
        let application = try Proxy.application(
            listeningOn: port,
            passPathsUnder: configuration.root,
            to: targetURL,
            configuration: configuration.configuration,
            takeDefaultsFrom: configuration.mainApplication,
            start: true
        )
        
        self.applications[port] = .init(
            application: application,
            targetURL: targetURL,
            configuration: configuration
        )
        
        return application
    }
    
    @discardableResult
    public func register<P>(ports: P, producingTargetURLWith targetURL: (Port) -> URL, configuration: Proxy.ProxyApplicationConfiguration = .default, mapConfigurationWith mapper: ((Port, Proxy.ProxyApplicationConfiguration) throws -> Proxy.ProxyApplicationConfiguration)? = nil) throws -> [Application] where P: Sequence, P.Element == Port {
        try ports.map { try self.register(
            port: $0,
            targetURL: targetURL($0),
            configuration: mapper?($0, configuration) ?? configuration
        )}
    }
    
    @discardableResult
    public func unregister(port: Port, shutdown: Bool = true) -> Application? {
        if shutdown, let application = self.applications[port] {
            application.application.shutdown()
        }
        return self.applications.removeValue(forKey: port)?.application
    }
    
    @discardableResult
    public func unregister<P>(ports: P, shutdown: Bool = true) -> [Application] where P: Sequence, P.Element == Port  {
        var result: [Application] = []
        
        for port in ports {
            if shutdown, let application = self.applications[port] {
                application.application.shutdown()
            }
            
            if let app = self.applications.removeValue(forKey: port)?.application {
                result.append( app )
            }
        }
        
        return result
    }
    
    @discardableResult
    public func set<P>(proxyPortsTo ports: P, producingTargetURLWith targetURL: (Port) -> URL, configuration: Proxy.ProxyApplicationConfiguration = .default, mapConfigurationWith mapper: ((Port, Proxy.ProxyApplicationConfiguration) throws -> Proxy.ProxyApplicationConfiguration)? = nil) throws -> (new: [Application], removed: [Application], replaced: [Application], unchanged: [Application]) where P: Sequence, P.Element == Port {
        var result: (new: [Application], removed: [Application], replaced: [Application], unchanged: [Application]) = (
            new: [],
            removed: [],
            replaced: [],
            unchanged: self.applications.values.map { $0.application }
        )
        
        for port in ports {
            let targetURL = targetURL(port)
            let configuration = try mapper?(port, configuration) ?? configuration
            
            if let application = self.applications[port] {
                if application.targetURL == targetURL &&
                    application.configuration == configuration {
                    continue
                }
                
                result.unchanged.removeAll { $0 === application.application }
                
                self.unregister(port: port)
                result.replaced.append(try self.register(
                    port: port,
                    targetURL: targetURL,
                    configuration: configuration
                ))
            } else {
                result.new.append(try self.register(
                    port: port,
                    targetURL: targetURL,
                    configuration: configuration
                ))
            }
        }
        
        result.removed = self.unregister(ports: self.applications.keys.filter { !ports.contains($0) })
        
        result.unchanged.removeAll { app in result.removed.contains { app === $0 } }

        return result
    }
}

extension Proxy.Pool {
    internal struct ProxyApplication {
        let application: Application
        let targetURL: URL
        let configuration: Proxy.ProxyApplicationConfiguration
    }
}

extension Proxy.ProxyApplicationConfiguration: Equatable {
    public static func == (lhs: Proxy.ProxyApplicationConfiguration, rhs: Proxy.ProxyApplicationConfiguration) -> Bool {
        lhs.configuration == rhs.configuration &&
        lhs.mainApplication === rhs.mainApplication &&
        lhs.root == rhs.root
    }
}
