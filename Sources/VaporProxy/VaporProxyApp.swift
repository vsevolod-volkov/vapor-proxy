//
//  VaporProxyApp.swift
//  
//
//  Created by Vsevolod Volkov on 17.07.2023.
//

import Foundation
import Vapor

extension Proxy {
    public enum ProxyError: Error {
        case mainApplicationNotStarted
    }
    
    public static func application(listeningOn port: Int, passPathsUnder root: String, to targetURL: URL, configuration: Configuration = .default, takeDefaultsFrom main: Application? = nil, start: Bool = true) throws -> Application {
        let app = Application(Environment(
            name: "Proxy server on \(port)",
            arguments: ["vapor", "serve", "--port", "\(port)"]
        ))
        
        if let main {
            guard let localAddress = main.http.server.shared.localAddress,
                  let hostname = localAddress.ipAddress else {
                throw ProxyError.mainApplicationNotStarted
            }
            app.http.server.configuration = main.http.server.configuration
            app.http.server.configuration.hostname = hostname
            app.http.server.configuration.port = port
            app.sessions.configuration = main.sessions.configuration
        }
        
        app.middleware.use( Proxy(passPathsUnder: root, to: targetURL, configuration: configuration) )
        
        if start { try app.start() }
        
        return app
    }
    
    public static func application(listeningOn port: Int, targetURL: URL, configuration: Configuration = .default, takeDefaultsFrom main: Application? = nil, start: Bool = true) throws -> Application {
        try Self.application(listeningOn: port, passPathsUnder: "/", to: targetURL, configuration: configuration, takeDefaultsFrom: main, start: start)
    }
}
