# vapor-proxy

Simple lightweight proxy [Vapor](https://github.com/vapor/vapor)-based framework.

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

### As middleware in your existing application
``` swift
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
```

### As separate application
``` swift
const proxyApp = try Proxy.application(
   listeningOn: 1234,
   passPathsUnder: "/proxy",
   to: URL(string: "http://destination.com:4321/destination-path")!,
   configuration: .init(log: true)
)

defer { proxyApp.shutdown() }
```
### As proxy pool
``` swift
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

// Unregister signle port
pool.unregister(port: 1234)

// Unregister port range
pool.unregister(port: 1234...4321)

// Automatically register new ports,
//  unregister unused ports and reinitialize
//  ports with changed configuration

try pool.set(proxyPortsTo: 1234...4321) {
   URL(string: "http://destination.com:\(10_000 + $0)/destination-path")!
}
```

## Proxy configuration

<table>
   <thead>
      <tr>
         <th>Property</th>
         <th>Type</th>
         <th>Default</th>
         <th>Description</th>
      </tr>
   </thead>
   <tbody>
      <tr>
         <td>log</td>
         <td>Bool</td>
         <td>false</td>
         <td>Enable proxy request logging</td>
      </tr>
      <tr>
         <td>forwardIP</td>
         <td>Bool</td>
         <td>true</td>
         <td>Enable X-Forwarded-xxx proxy request header generation</td>
      </tr>
      <tr>
         <td>preserveHost</td>
         <td>Bool</td>
         <td>false</td>
         <td>Keep Host header as received from user agent</td>
      </tr>
      <tr>
         <td>preserveCookiePath</td>
         <td>Bool</td>
         <td>false</td>
         <td>Do not change cookie paths</td>
      </tr>
      <tr>
         <td>handleRedirects</td>
         <td>Bool</td>
         <td>false</td>
         <td>Peocess redirects internally so user agent fetches only final page</td>
      </tr>
      <tr>
         <td>connectTimeout</td>
         <td>Int?</td>
         <td>nil</td>
         <td>An integer to set the HTTP-client socket connection timeout (milliseconds)</td>
      </tr>
      <tr>
         <td>readTimeout</td>
         <td>Int?</td>
         <td>nil</td>
         <td>An integer to set the HTTP-client socket read timeout (milliseconds)</td>
      </tr>
      <tr>
         <td>certificateVerification</td>
         <td><a href="https://github.com/apple/swift-nio-ssl">NIOSSL</a>.CertificateVerification</td>
         <td>.fullVerification</td>
         <td>Sets how HTTP-client deals with server SSL/TLS certificates</td>
      </tr>
      <tr>
         <td>dnsOverride</td>
         <td>[String: String]?</td>
         <td>nil</td>
         <td>Allows to setup HTTP-client domain name translation</td>
      </tr>
      <tr>
         <td>maxBodySize</td>
         <td>ByteCount?</td>
         <td>nil</td>
         <td>Allows to override default Vapor payload size limit</td>
      </tr>
   </tbody>
</table>

## Proxy pool configuration

<table>
   <thead>
      <tr>
         <th>Property</th>
         <th>Type</th>
         <th>Default</th>
         <th>Description</th>
      </tr>
   </thead>
   <tbody>
      <tr>
         <td>root</td>
         <td>String</td>
         <td>/</td>
         <td>Sets top-level path to access proxied resource</td>
      </tr>
      <tr>
         <td>configuration</td>
         <td>Proxy.Configuration</td>
         <td>.default</td>
         <td>Proxy middleware configuration</td>
      </tr>
      <tr>
         <td>mainApplication</td>
         <td>Application?</td>
         <td>nil</td>
         <td><a href="https://github.com/vapor/vapor)">Vapor</a> Application to take default configuration parameters from</td>
      </tr>
   </tbody>
</table>
