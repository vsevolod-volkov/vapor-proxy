//
//  VaporProxy.swift
//  
//
//  Created by Vsevolod Volkov on 14.07.2023.
//

import Foundation
import Vapor
import NIOCore
import NIOSSL

public final class Proxy: AsyncMiddleware {
    public let configuration: Configuration
    fileprivate let root: String
    public let targetURL: URL
    fileprivate var httpClient: HTTPClient!
    
    public init(passPathsUnder root: String, to targetURL: URL, configuration: Configuration = .default) {
        self.root = String(root.trimmingSuffix { $0 == "/"})
        self.targetURL = targetURL
        self.configuration = configuration
    }
    
    public static func application(listeningOn port: Int, passPathsUnder root: String, to targetURL: URL, configuration: Configuration = .default, takeDefaultsFrom main: Application? = nil) throws -> Application {
        let app = Application(Environment(
            name: "Proxy server on \(port)",
            arguments: ["vapor", "serve"]
        ))
        
        if let main {
            app.http.server.configuration = main.http.server.configuration
            app.http.server.configuration.port = port
        }
        
        app.middleware.use( Proxy(passPathsUnder: root, to: targetURL, configuration: configuration) )
        
        try app.start()
        
        return app
    }
    
    public static func application(listeningOn port: Int, targetURL: URL, configuration: Configuration = .default, takeDefaultsFrom main: Application? = nil) throws -> Application {
        try Self.application(listeningOn: port, passPathsUnder: "/", to: targetURL, configuration: configuration, takeDefaultsFrom: main)
    }
}

extension Proxy {
    public struct Configuration {
        /// Enable proxy request logging
        public var log: Bool
        
        /// Enable X-Forwarded-xxx proxy request header generation
        public var forwardIP: Bool
        
        /// Keep Host header as received from user agent
        public var preserveHost: Bool
        
        /// Do not change cookie paths
        public var preserveCookiePath: Bool
        
        /// Peocess redirects internally so user agent fetches only final page
        public var handleRedirects: Bool
        
        /// An integer to set the HTTP-client socket connection timeout (milliseconds)
        public var connectTimeout: Int?
        
        /// An integer to set the HTTP-client socket read timeout (milliseconds)
        public var readTimeout: Int?
        
        /// Sets how HTTP-client deals with server SSL/TLS certificates
        public var certificateVerification: CertificateVerification
        
        /// Allows to setup HTTP-client domain name translation
        public var dnsOverride: [String: String]?
        
        public static let `default` = Configuration()
        
        public init(log: Bool = false,
                    forwardIP: Bool = true,
                    preserveHost: Bool = false,
                    preserveCookiePath: Bool = false,
                    handleRedirects: Bool = false,
                    connectTimeout: Int? = nil,
                    readTimeout: Int? = nil,
                    certificateVerification: CertificateVerification = .fullVerification,
                    dnsOverride: [String : String]? = nil) {
            self.log = log
            self.forwardIP = forwardIP
            self.preserveHost = preserveHost
            self.preserveCookiePath = preserveCookiePath
            self.handleRedirects = handleRedirects
            self.connectTimeout = connectTimeout
            self.readTimeout = readTimeout
            self.certificateVerification = certificateVerification
            self.dnsOverride = dnsOverride
        }
    }
    
    public func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let proxyPath: String
        if request.url.path == self.root {
            proxyPath = self.targetURL.path
        } else if request.url.path.hasPrefix("\(self.root)/") {
            let startIndex = request.url.path.index(request.url.path.startIndex, offsetBy: self.root.count)
            let endIndex = request.url.path.endIndex
            proxyPath = concatWithSlash(self.targetURL.path, request.url.path[startIndex..<endIndex])
        } else {
            return try await next.respond(to: request)
        }
        
        let proxyURL = URI(
            scheme: self.targetURL.scheme,
            host: self.targetURL.host,
            port: self.targetURL.port,
            path: proxyPath,
            query: request.url.query,
            fragment: self.targetURL.fragment ?? request.url.fragment
        )
        
        if self.configuration.log {
            request.application.logger.log(level: .info, "🔴 \(request.method) \(request.url.path) → \(proxyURL.path)")
        }
        let body: ByteBuffer?
        //RFC 2616 4.3
        if  request.headers.contains(name: .contentLength) ||
            request.headers.contains(name: .transferEncoding) {
            body = try await request.body.collect().get()
        } else {
            body = nil
        }
        
        let proxyRequest = try HTTPClient.Request(
            url: proxyURL.string,
            method: request.method,
            headers: self.get(proxyRequestHeadersFor: request),
            body: body.map { .byteBuffer($0) }
        )
        
        if self.httpClient == nil {
            var configuration = HTTPClient.Configuration(
                certificateVerification: self.configuration.certificateVerification,
                redirectConfiguration: self.configuration.handleRedirects ? nil : .disallow,
                timeout: .init(
                    connect: self.configuration.connectTimeout.map { .milliseconds(Int64($0)) },
                    read: self.configuration.readTimeout.map { .milliseconds(Int64($0)) }
                )
            )
            
            if let dnsOverride = self.configuration.dnsOverride {
                configuration.dnsOverride = dnsOverride
            }
            
            self.httpClient = HTTPClient(eventLoopGroupProvider: .createNew, configuration: configuration)
        }
        let proxyResponse = try await self.httpClient.execute(request: proxyRequest).get()

        if let body = proxyResponse.body {
            return Response(
                status: proxyResponse.status,
                headers: get(responseHeadersFor: proxyResponse, originalRequest: request),
                body: .init(buffer: body)
            )
        } else {
            return Response(
                status: proxyResponse.status,
                headers: get(responseHeadersFor: proxyResponse, originalRequest: request)
            )
        }
    }
}

extension Proxy {
    fileprivate typealias ProxyResponse = HTTPClient.Response
    
    private static let hopByHopHeaders: [HTTPHeaders.Name] = [
        .connection,
        .keepAlive,
        .proxyAuthenticate,
        .proxyAuthorization,
        .te,
        "Trailers",
        .transferEncoding,
        .upgrade,
    ]
    
    private func get(proxyRequestHeadersFor request: Request) -> HTTPHeaders {
        var proxyRequestHeaders = HTTPHeaders()
        proxyRequestHeaders.reserveCapacity(request.headers.count)
        
        for (header, value) in request.headers {
            let name = HTTPHeaders.Name(header)
            
            switch name {
            case .cookie, .cookie2, .contentLength:
                break
            case .host:
                guard !self.configuration.preserveHost, let host = self.get(hostFrom: URI(string: self.targetURL.absoluteString)) else {
                    proxyRequestHeaders.add(name: header, value: value)
                    break
                }
                
                proxyRequestHeaders.add(name: header, value: host)
            case .xForwardedFor:
                if self.configuration.forwardIP {
                    if let remoteAddress = request.remoteAddress?.ipAddress {
                        proxyRequestHeaders.add(name: header, value: "\(value), \(remoteAddress)")
                    } else {
                        proxyRequestHeaders.add(name: header, value: value)
                    }
                } else {
                    proxyRequestHeaders.add(name: header, value: value)
                }
            case .xForwardedProto, .xForwardedHost:
                if self.configuration.forwardIP {
                    break
                } else {
                    proxyRequestHeaders.add(name: header, value: value)
                }
            default:
                guard !Self.hopByHopHeaders.contains(name) else { break }
                proxyRequestHeaders.add(name: header, value: value)
            }
        }
        
        if self.configuration.forwardIP {
            if !proxyRequestHeaders.contains(name: HTTPHeaders.Name.xForwardedFor),
               let remoteAddress = request.remoteAddress?.ipAddress {
                
                proxyRequestHeaders.add(name: HTTPHeaders.Name.xForwardedFor, value: remoteAddress)
            }
            
            if let scheme = request.url.scheme {
                proxyRequestHeaders.add(name: HTTPHeaders.Name.xForwardedProto, value: scheme)
            }
            
            if let host = request.headers[HTTPHeaders.Name.host].first {
                proxyRequestHeaders.add(name: HTTPHeaders.Name.xForwardedHost, value: host)
            } else if let host = get(hostFrom: request.url) {
                proxyRequestHeaders.add(name: HTTPHeaders.Name.xForwardedHost, value: host)
            }
        }
        
        if let cookies = request.headers.cookie?.all {
            var proxyCookies = HTTPCookies()
            
            for (name, value) in cookies {
                if self.configuration.preserveCookiePath {
                    proxyCookies[name] = value
                } else {
                    var value = value
                    if let path = value.path {
                        value.path = concatWithSlash(self.targetURL.path, path)
                    } else {
                        value.path = self.targetURL.path
                    }
                    proxyCookies[name] = value
                }
            }
            
            proxyRequestHeaders.cookie = proxyCookies
        }
        
        return proxyRequestHeaders
    }
    
    private func get(responseHeadersFor response: ProxyResponse, originalRequest request: Request) -> HTTPHeaders {
        var responseHeaders = HTTPHeaders()
        responseHeaders.reserveCapacity(response.headers.count)
        
        for (header, value) in response.headers {
            let name = HTTPHeaders.Name(header)
            
            switch name {
            case .setCookie, .setCookie2, .contentLength:
                break
            case .location:
                guard let original = URL(string: value, relativeTo: self.targetURL) else {
                    responseHeaders.add(name: header, value: value)
                    break
                }
                
                let url = URI(
                    scheme: original.scheme == nil ? nil : request.url.scheme,
                    host: original.host == nil ? nil : request.url.host,
                    port: original.host == nil ? nil : request.url.port,
                    path: self.concatWithSlash(self.targetURL.path, original.path),
                    query: original.query,
                    fragment: original.fragment
                )
                
                responseHeaders.add(name: header, value: self.concatWithSlash(self.targetURL.path, url.string))
            default:
                guard !Self.hopByHopHeaders.contains(name) else { break }
                responseHeaders.add(name: header, value: value)
            }
        }

        if let cookies = response.headers.setCookie?.all {
            var responseCookies = HTTPCookies()
            
            for (name, value) in cookies {
                if self.configuration.preserveCookiePath {
                    responseCookies[name] = value
                } else {
                    var value = value
                    if let path = value.path {
                        value.path = concatWithSlash(self.targetURL.path, path)
                    } else {
                        value.path = self.targetURL
                            .path
                    }
                    responseCookies[name] = value
                }
            }
            
            responseHeaders.setCookie = responseCookies
        }

        return responseHeaders
    }
    
    private func concatWithSlash<S>(_ first: String, _ second: S) -> String where S: StringProtocol {
        var result = first
        result.reserveCapacity(first.count + 1 + second.count)
        
        if first.hasSuffix("/") {
            if second.hasPrefix("/") {
                result.removeLast()
            }
        } else {
            if !second.hasPrefix("/") {
                result.append("/")
            }
        }
        
        result.append(contentsOf: second)
        
        return result
    }
    
    private func get(hostFrom uri: URI) -> String? {
        guard let host = uri.host else { return nil }
        
        if let port = uri.port {
            return "\(host):\(port)"
        } else {
            return host
        }
    }
}
