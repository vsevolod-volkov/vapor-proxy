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
        guard let proxyPath = self.finalPath(requestPath: request.url.path, root: self.root) else {
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
                guard let original = URL(string: value, relativeTo: self.targetURL),
                      original.host == self.targetURL.host,
                      original.port == self.targetURL.port,
                      let locationPath = self.finalPath(requestPath: original.path, root: self.targetURL.path) else {
                    responseHeaders.add(name: header, value: value)
                    break
                }
                
                let locationURL = URI(
                    scheme: original.scheme == nil ? nil : request.application.http.server.configuration.tlsConfiguration == nil ? "http" : "https",
                    host: original.host == nil ? nil : request.application.http.server.configuration.hostname,
                    port: original.host == nil ? nil : request.application.http.server.configuration.port,
                    path: self.concatWithSlash(self.root, Self.escape(partiallyEscapedURL: locationPath, withPercents: false)),
                    query: original.query,
                    fragment: original.fragment
                )

                responseHeaders.add(name: header, value: locationURL.string)
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
    
    private func finalPath(requestPath: String, root: String) -> String? {
        if requestPath == root {
            return self.targetURL.path
        } else if requestPath.hasPrefix("\(root)/") {
            let startIndex = requestPath.index(requestPath.startIndex, offsetBy: root.count)
            let endIndex = requestPath.endIndex
            return self.concatWithSlash(self.targetURL.path, requestPath[startIndex..<endIndex])
        } else {
            return nil
        }
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
    
    private static let plainCharacters: CharacterSet = .controlCharacters.union(.whitespaces)
    private static let unescapedNoPercent: CharacterSet = .urlQueryAllowed.union(["%"])
    private static let unescapedWithPercent: CharacterSet = .urlQueryAllowed
    
    internal static func escape(partiallyEscapedURL url: String, withPercents percent: Bool) -> String {
        let unescaped = percent ? Self.unescapedWithPercent : Self.unescapedNoPercent
        
        func toBeEscaped(_ character: Character) -> Bool {
            let unicode = character.unicodeScalars.first!
            
            if let ascii = character.asciiValue, ascii < 128 {
                return !unescaped.contains(unicode)
            } else {
                return !Self.plainCharacters.contains(unicode)
            }
        }
        
        guard let firstEscaped = url.firstIndex(where: toBeEscaped) else {
            return url
        }
        
        var result = String(url[..<firstEscaped])
        
        result.reserveCapacity(url.count * 3)
        
        let remainder = url[firstEscaped...]
        
        var i = remainder.makeIterator()
        
        while let character = i.next() {
            if toBeEscaped(character) {
                result.append(contentsOf: character.utf8.map { String(format: "%%%02X", $0) }.joined())
            } else {
                result.append(character)
            }
        }
        return result
    }
}
