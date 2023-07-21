# vapor-proxy

Simple proxy framework based for Vapor.

## Installation

Add to your Package.swift:

      let package = Package(
         ...
         dependencies: [
            .package(url: "https://github.com/vsevolod-volkov/vapor-proxy.git", from: "0.4.0"),
         ],
         targets: [
            .target(
               ...
               dependencies: [
                  .product(name: "VaporProxy", package: "vapor-proxy"),
               ],
            ),
         ]
      )

Add to your swift module:

      import VaporProxy

## Basic use cases

### As middleware in your existent application
      func routes(_ app: Application) throws {
         app.get { req async in
            "It works!"
         }

         app.middleware.use( Proxy(
            passPathsUnder: "/proxy",
            to: URL(string: "http://destination.com:4321/destination-path")!,
            configuration: .init(log: true)
         ))
      }

### As separate application
      const proxyApp = try Proxy.application(
         listeningOn: 1234,
         passPathsUnder: "/proxy",
         to: URL(string: "http://destination.com:4321/destination-path")!,
         configuration: .init(log: true)
      )

      defer { proxyApp.shutdown() }

### As proxy pool
      let pool = Proxy.Pool()
      
      // Register single port
      try pool.register(
         port: 1234, 
         targetURL: URL(string: "http://destination.com:4321/destination-path")!
      )
      
      // Register port range
      try pool.register(ports: 1234...4321) {
         URL(string: "http://destination.com:\(10_000 + $0)/destination-path")!
      }
      
      // Register port list
      try pool.register(ports: [5432, 2345]) {
         URL(string: "http://destination.com:\(10_000 + $0)/destination-path")!
      }
