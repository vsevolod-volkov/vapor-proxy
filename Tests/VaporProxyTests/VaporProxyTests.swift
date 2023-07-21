@testable import VaporProxy
import XCTVapor

final class VaporProxyTests: XCTestCase {
    var serverApp: Application!
    var proxyApp: Application!
    
    static let serverPort = 3000
    static let proxyPort = 3001
    static let secondProxyPort = 3002
    static let localhost = "127.0.0.1"
    let proxyURI: URI = "http://\(localhost):\(proxyPort)/proxyMe"
    
    let echoMethodPathQueryFragment = "echo-method-path-query-fragment"
    
    override func setUp() async throws {
        serverApp = Application(Environment(
            name: "Test server",
            arguments: ["serverApp", "serve", "--port", "\(Self.serverPort)"]
        ))
        
        for method: HTTPMethod in [.GET, .POST] {
            func process(_ request: Request) async throws -> some AsyncResponseEncodable {
                var response = request.url.path
                
                response.removeFirst("/\(self.echoMethodPathQueryFragment)".count)
                
                if let query = request.url.query {
                    response += "?\(query)"
                }
                if let fragment = request.url.fragment {
                    response += "#\(fragment)"
                }
                return Response(body: .init(stringLiteral: "\(request.method.string):\(response)"))
            }
            
            serverApp.on(method, .init(stringLiteral: echoMethodPathQueryFragment), use: process)
            serverApp.on(method, .init(stringLiteral: echoMethodPathQueryFragment), "**", use: process)
        }
        
        func testRedirect(_ request: Request) async throws -> some AsyncResponseEncodable {
            var headers: HTTPHeaders = [
                "Location": request.headers["X-Proxy-Test-Target"].first ?? "/",
            ]
            
            headers.setCookie = [
                "TestCookie": .init(string: "Test value", path: "/"),
            ]
            return Response(status: .temporaryRedirect, headers: headers)
        }
        serverApp.get("testRedirect", use: testRedirect)
        serverApp.get("testRedirect", "**", use: testRedirect)
        
        serverApp.post("file") { request in
            guard let byteBuffer = try await request.body.collect().get() else {
                return Response(status: .badRequest)
            }
            return Response(body: .init(buffer: byteBuffer))
        }
        
        serverApp.get("echo-header") { request in
            let query = try ContentConfiguration.global.requireURLDecoder().decode([String: String].self, from: request.url)
            
            guard let header = query["header"] else {
                return Response(status: .badRequest, body: "Need header field")
            }
            
            if let header = request.headers[header].first {
                return Response(body: .init(stringLiteral: header))
            } else {
                return Response()
            }
        }
        
        serverApp.get("return-header") { request in
            let query = try ContentConfiguration.global.requireURLDecoder().decode([String: String].self, from: request.url)
            
            guard let header = query["header"] else {
                return Response(status: .badRequest, body: "Need header field")
            }
            
            return Response(headers: [
                header: query["value"] ?? ""
            ])
        }
        
        serverApp.get("set-coolie") { request in
            var headers = HTTPHeaders()
            
            headers.setCookie = request.headers.cookie
            
            return Response(headers: headers)
        }
        try serverApp.start()
        
        proxyApp = try Proxy.application(
            listeningOn: Self.proxyPort,
            passPathsUnder: "/proxyMe",
            to: URL(string: "http://\(Self.localhost):\(Self.serverPort)")!,
            configuration: .init(log: true)
        )
    }
    
    override func tearDown() async throws {
        proxyApp.shutdown()
        serverApp.shutdown()
    }
    
    private func testSuffixes(method: HTTPMethod) async throws {
        let testURLSuffixes = [
            "","/pathInfo","/pathInfo/%23%25abc","?q=v","/p?q=v",
            "/p?query=note:Leitbild",//colon  Issue#4
            "/p?query=note%3ALeitbild",
            "/p?id=p%20i", "/p%20i", // encoded space in param then in path
            "/p?id=p+i",
            "/pathwithquestionmark%3F%3F?from=1&to=10" // encoded question marks
        ]
        
        let client = HTTPClient(eventLoopGroupProvider: .createNew)
        
        defer { try! client.syncShutdown() }
        
        for urlSuffix in testURLSuffixes {
            let res = try await client.execute(method, url: "\(proxyURI)/\(echoMethodPathQueryFragment)\(urlSuffix)").get()
            
            XCTAssertEqual(res.status, .ok)
            if let body = res.body?.string {
                XCTAssertEqual(body, "\(method.string):\(urlSuffix)")
            } else {
                XCTFail("No response body.")
            }
        }
    }
    
    func testGET() async throws {
        try await self.testSuffixes(method: .GET)
    }
    func testPOST() async throws {
        try await self.testSuffixes(method: .POST)
    }
    
    func testRedirect() async throws {
        let sourceURL = "\(proxyURI)/testRedirect"
        let targetURI = "http://\(Self.localhost):\(Self.serverPort)/testRedirect"
        let redirects: [(source: String, target: String)] = [
            (source: "http://not.existent.domain.com/path?query=value#fragment", target: "http://not.existent.domain.com/path?query=value#fragment"),
            (source: "\(proxyURI)/testRedirect/first+second", target: "\(targetURI)/first+second"),
            (source: "\(proxyURI)/testRedirect/first+second?name=value", target: "\(targetURI)/first+second?name=value"),
            (source: "\(proxyURI)/testRedirect/first+second?name=value#frag", target: "\(targetURI)/first+second?name=value#frag"),
            (source: "\(proxyURI)/testRedirect/first+second?name+second-name=value%20c#frag%23", target: "\(targetURI)/first+second?name+second-name=value%20c#frag%23"),
            (source: "\(proxyURI)/testRedirect/first%20second", target: "\(targetURI)/first%20second"),
            (source: "\(proxyURI)/testRedirect/first%20second?name=value", target: "\(targetURI)/first%20second?name=value"),
            (source: "\(proxyURI)/testRedirect/first%20second?name=value#frag", target: "\(targetURI)/first%20second?name=value#frag"),
            (source: "\(proxyURI)/testRedirect/path?name=value", target: "\(targetURI)/path?name=value"),
        ]
        
        let client = HTTPClient(eventLoopGroupProvider: .createNew, configuration: .init(redirectConfiguration: .disallow))
        
        defer { try! client.syncShutdown() }
        
        for redirect in redirects {
            print(redirect)
            var request = try HTTPClient.Request(url: sourceURL, method: .GET)
            
            request.headers.add(name: "X-Proxy-Test-Target", value: redirect.target)
            
            let res = try await client.execute(request: request).get()
            print(res)
            XCTAssertEqual(res.status, .temporaryRedirect)
            XCTAssertNil(res.body)
            XCTAssertEqual(res.headers["Location"], [redirect.source])
            XCTAssertEqual((res.headers.setCookie?.all ?? [:]).map { "\($0.key):\($0.value.string)" }, [
                "TestCookie:\(HTTPCookies.Value(string: "Test value", path: proxyURI.string).string)",
            ])
        }
    }
    
    func testFile() async throws {
        let client = HTTPClient(eventLoopGroupProvider: .createNew)
        
        defer { try! client.syncShutdown() }
        
        let fileURL = URL(fileURLWithPath: #file)
        var request = URLRequest(url: URL(string: "\(proxyURI)/file")!)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        XCTAssertEqual(
            String(data: data, encoding: .utf8) ?? "",
            String(data: try .init(contentsOf: fileURL), encoding: .utf8)!
        )
    }
    
    func testProxyWithUnescapedChars() async throws {
        let tests = [
            (original: "\(proxyURI)?field1=%7B!field2=value%7D", expected: "\(proxyURI)?field1=%257B!field2=value%257D", percent: true),
            (original: "\(proxyURI)?field1={!field2=value}",     expected: "\(proxyURI)?field1=%7B!field2=value%7D",     percent: false),
            (original: "\(proxyURI)?field1=%7B!field2=value%7D", expected: "\(proxyURI)?field1=%7B!field2=value%7D",     percent: false),
            (original: "\(proxyURI)/%5Bpath-segment-1%5D/path-segment-2",     expected: "\(proxyURI)/%5Bpath-segment-1%5D/path-segment-2",         percent: false),
        ]
        
        for test in tests {
            XCTAssertEqual(Proxy.escape(partiallyEscapedURL: test.original, withPercents: test.percent), test.expected)
        }
    }
    
    func testTransferClientHeader() async throws {
        let tests: [(header: String, value: String?, expected: String)] = [
            (header: "Proxy-Authenticate", value: "Proxy-Authenticate value", expected: ""),
            (header: "X-My-Header",        value: "Value of X-My-Header",     expected: "Value of X-My-Header"),
            (header: "X-Forwarded-For",    value: nil,                        expected: Self.localhost),
            (header: "X-Forwarded-For",    value: "1.2.3.4",                  expected: "1.2.3.4, \(Self.localhost)"),
        ]
        
        let client = HTTPClient(eventLoopGroupProvider: .createNew)
        
        defer { try! client.syncShutdown() }
        
        for test in tests {
            var uri = URI("\(proxyURI)/echo-header")
            try ContentConfiguration.global.requireURLEncoder().encode([
                "header": test.header,
            ], to: &uri)
            let request = try HTTPClient.Request(url: uri.string, method: .GET, headers: test.value == nil ? [:] : [test.header: test.value!])
            
            let response = try await client.execute(request: request).get()
            
            XCTAssertEqual(response.body?.string ?? "", test.expected)
        }
    }
    
    func testTransferServerHeader() async throws {
        let tests: [(header: String, value: String, expected: String)] = [
            (header: "X-My-Header",        value: "Value of X-My-Header",     expected: "Value of X-My-Header"),
        ]
        
        let client = HTTPClient(eventLoopGroupProvider: .createNew)
        
        defer { try! client.syncShutdown() }
        
        for test in tests {
            var uri = URI("\(proxyURI)/return-header")
            try ContentConfiguration.global.requireURLEncoder().encode([
                "header": test.header,
                "value": test.value,
            ], to: &uri)
            
            let response = try await client.get(url: uri.string).get()
            
            XCTAssertEqual(response.headers[test.header], [test.expected])
        }
    }
    
    func testCookieHeader() async throws {
        let tests: [(cookie: String, value: HTTPCookies.Value)] = [
            (cookie: "My-Cookue",          value: "My-Cookue value"),
            (cookie: "My-Cookue",          value: .init(string: "VaLuE", expires: Date().addingTimeInterval(86400), domain: "some.domain.org", path: "/proxyMe/aome/path/")),
            (cookie: "My-Cookue",          value: .init(string: "xxx", path: "/proxyMe/aome/path/", isHTTPOnly: true)),
        ]
        
        let client = HTTPClient(eventLoopGroupProvider: .createNew)
        
        defer { try! client.syncShutdown() }
        
        for test in tests {
            let uri = URI("\(proxyURI)/set-coolie")
            var headers = HTTPHeaders()
            headers.cookie = [
                test.cookie: test.value,
            ]
            let request = try HTTPClient.Request(url: uri.string, method: .GET, headers: headers)
            
            let response = try await client.execute(request: request).get()
            
            XCTAssertEqual(response.headers.setCookie?[test.cookie]?.string ?? .init(), test.value.string)
        }
    }
    
    func testConcurrentCookies() async throws {
        let count = 100
        
        let uri = URI("\(proxyURI)/set-coolie")
        
        let client = HTTPClient(eventLoopGroupProvider: .createNew)
        
        defer { try! client.syncShutdown() }
        
        for i in 1...count {
            var headers = HTTPHeaders()
            let cookie = "Test-Cookie-\(i)"
            let value = HTTPCookies.Value(stringLiteral: "Test-Cookie-\(i)-Value")
            headers.cookie = [cookie: value]
            
            let request = try HTTPClient.Request(url: uri.string, method: .GET, headers: headers)
            
            let response = try await client.execute(request: request).get()
            
            XCTAssertEqual(response.headers.setCookie?[cookie]?.string ?? .init(), value.string)
            XCTAssertEqual(response.headers.setCookie?.all.keys.map { "\($0)" } , [cookie])
        }
    }
    
    func testPreserveHost() async throws {
        let proxyApp = try Proxy.application(
            listeningOn: Self.secondProxyPort,
            passPathsUnder: "/proxyMe",
            to: URL(string: "http://\(Self.localhost):\(Self.serverPort)")!,
            configuration: .init(log: true, preserveHost: true)
        )
        
        defer { proxyApp.shutdown() }
        
        let client = HTTPClient(eventLoopGroupProvider: .createNew)
        
        defer { try! client.syncShutdown() }
        
        let response = try await client.get(url: "http://\(Self.localhost):\(Self.secondProxyPort)/proxyMe/echo-header?header=Host").get()
        
        XCTAssertEqual(response.body?.string ?? "", "\(Self.localhost):\(Self.secondProxyPort)")
    }
    
    func testPool() async throws {
        let pool = Proxy.Pool()
        
        try pool.register(port: 3030, targetURL: URL(string: "http://\(Self.localhost):\(Self.serverPort)")!)
        
        try pool.register(ports: 3031...3036, producingTargetURLWith: { _ in URL(string: "http://\(Self.localhost):\(Self.serverPort)")! })
        try pool.register(ports: [3037, 3038, 3039], producingTargetURLWith: { _ in URL(string: "http://\(Self.localhost):\(Self.serverPort)")! })
        
        let client = HTTPClient(eventLoopGroupProvider: .createNew)
        
        defer { try! client.syncShutdown() }
        
        for port in 3030...3039 {
            let sourceUri: URI = "http://\(Self.localhost):\(port)"
            let urlSuffix = "/test-for-port-\(port)"
            let res = try await client.get(url: "\(sourceUri)/\(echoMethodPathQueryFragment)\(urlSuffix)").get()
            
            XCTAssertEqual(res.status, .ok)
            if let body = res.body?.string {
                XCTAssertEqual(body, "GET:\(urlSuffix)")
            } else {
                XCTFail("No response body.")
            }
        }
        
        let port = 3035
        pool.unregister(port: port)
        
        let quickClient = HTTPClient(eventLoopGroupProvider: .createNew, configuration: .init(timeout: .init(connect: .seconds(1))))
        
        defer { try! quickClient.syncShutdown() }
        
        XCTAssertThrowsError(try quickClient.get(url: "http://\(Self.localhost):\(port)/\(echoMethodPathQueryFragment)/FAILURE").wait())
    }
    
    func testPoolSet() async throws {
        let pool = Proxy.Pool()
        
        let configuration1: Proxy.ProxyApplicationConfiguration = .default
        let configuration2: Proxy.ProxyApplicationConfiguration = .init(root: "/root")

        try pool.register(ports: 3030...3039, producingTargetURLWith: { _ in URL(string: "http://\(Self.localhost):\(Self.serverPort)")! }, configuration: configuration1)
        
        for (_, proxyApp) in pool.applications {
            XCTAssertEqual(proxyApp.configuration, configuration1)
        }

        try pool.set(proxyPortsTo: 3030...3039, producingTargetURLWith: { _ in URL(string: "http://\(Self.localhost):\(Self.serverPort)")! }, mapConfigurationWith: { port, configuration in
            port % 2 == 0 ? configuration1 : configuration2
        })

        for (port, proxyApp) in pool.applications {
            XCTAssertEqual(proxyApp.configuration, port % 2 == 0 ? configuration1 : configuration2)
        }
    }
}
