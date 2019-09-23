//
//  streams_swiftTests.swift
//  streams-swiftTests
//
//  Created by Davide Bertola on 17/09/2019.
//  Copyright © 2019 Davide Bertola. All rights reserved.
//

import XCTest
@testable import stream_swift


class StreamTests: XCTestCase {

    override func setUp() {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        XCTAssertTrue(SubscriptionTracker.sharedInstance.validate())
    }
    
    func testSubscribeByTarget() {
        let stream = Stream<String?>()
        var result: String? = nil
        stream.subscribe(self) { string in
            result = string
        }
        stream.trigger("ciao")
        stream.trigger("mondo")
        XCTAssertEqual("mondo", result)
        stream.dispose()
    }
    
    func testUnsubscribeByTarget() {
        let stream = Stream<String?>()
        var result: String? = nil
        stream.subscribe(self) { string in
            result = string
        }
        stream.trigger("ciao")
        stream.unsubscribe(self)
        stream.trigger("mondo")
        XCTAssertEqual("ciao", result)
        stream.dispose()
    }
    
    func testSubscribeSimple() {
        let stream = Stream<String?>()
        var result: String? = nil
        stream.subscribe() { string in
            result = string
        }
        stream.trigger("ciao").trigger("mondo")
        XCTAssertEqual("mondo", result)
        stream.dispose()
    }
    
    func testUnsubscribeSimple() {
        let stream = Stream<String?>()
        var result: String? = nil
        let sub = stream.subscribe() { string in
            result = string
        }
        stream.trigger("ciao")
        sub.dispose()
        stream.trigger("mondo")
        XCTAssertEqual("ciao", result)
        stream.dispose()
    }
    
    func testNoValue() {
        let stream = Stream<Unit?>()
        var called = false
        stream.subscribe() { _ in called = true }
        stream.trigger(nil)
        XCTAssertEqual(true, called)
        stream.dispose()
    }
    
    func testLast() {
        let stream = Stream<String>()
        XCTAssertEqual(false, stream.valuePresent)
        stream.last { XCTAssertEqual(nil, $0) }
        stream.trigger("1")
        XCTAssertEqual(true, stream.valuePresent)
        stream.last { XCTAssertEqual("1", $0) }
    }
    
    func testLastOptional() {
        let stream = Stream<String?>()
        XCTAssertEqual(false, stream.valuePresent)
        stream.last { XCTAssertEqual(nil, $0) }
        stream.trigger(nil)
        XCTAssertEqual(true, stream.valuePresent)
        stream.last { XCTAssertEqual(nil, $0) }
        stream.trigger("1")
        XCTAssertEqual(true, stream.valuePresent)
    }
    
    func testReplay() {
        let stream = Stream<String?>()
        stream.trigger("ciao")
        var result: String? = nil
        stream.subscribe(replay: true) { string in
            result = string
        }
        XCTAssertEqual("ciao", result)
        stream.dispose()
    }
    
    func testReplayWithNoValue() {
        let stream = Stream<String?>()
        var called = false
        stream.subscribe(replay: true) { _ in
            called = true
        }
        XCTAssertEqual(false, called)
        stream.dispose()
    }
    
    func testMap() {
        let stream = Stream<Int?>()
        var result = [String]()
        stream.trigger(nil)
        stream
            .map { $0?.description ?? "" }
            .subscribe(replay: true) { result += [$0] }
        stream.trigger(1).trigger(2)
        XCTAssertEqual(["", "1",  "2"], result)
        stream.dispose()
    }
    
    func testDistinct() {
        let stream = Stream<String?>()
        var result = [String?]()
        stream.distinct({ $0 }).subscribe(replay: true) { result += [$0] }
        stream
            .trigger(nil).trigger(nil)
            .trigger("1")
            .trigger("2").trigger("2")
            .trigger(nil)
            .trigger("3").trigger("3").trigger("3")
            .trigger(nil).trigger(nil)
        XCTAssertEqual([nil, "1", "2", nil, "3", nil], result)
        stream.dispose()
    }
    
    func testDistinctNoLeak() {
        let stream = Stream<String?>()
        var result = [String?]()
        stream.distinct({ $0 }).subscribe(replay: true) { result += [$0] }
        XCTAssertEqual([], result)
        stream.dispose()
    }
    
    func testFold() {
        let stream = Stream<String?>()
        var result: (String?, String?) = (nil, nil)
        let sub = stream
            .trigger(nil)
            .fold(initialValue: (nil, nil)) { ($0.1, $1) }
            .subscribe(replay: true) { (pair) in
                result = pair
            }
        XCTAssertEqual(nil, result.0)
        XCTAssertEqual(nil, result.1)
        stream.trigger("1")
        XCTAssertEqual(nil, result.0)
        XCTAssertEqual("1", result.1)
        stream.trigger("2")
        XCTAssertEqual("1", result.0)
        XCTAssertEqual("2", result.1)
        stream.trigger(nil)
        XCTAssertEqual("2", result.0)
        XCTAssertEqual(nil, result.1)
        stream.dispose()
    }
    
    func testCombine() {
        let a = Stream<String?>()
        let b = Stream<String?>()
        var result = [(String?, String?)]()
        // tuple of equatable values should be equatable in general ?
        let merge: ((String?, String?)) -> String = { "\($0.0)\($0.1)" }
        combine(a, b).distinct({ merge($0) }).subscribe { tuple in
            result += [tuple]
        }
        a.trigger("1")
        b.trigger(nil)
        b.trigger("2")
        a.trigger("2")
        a.trigger("2")
        a.dispose()
        b.trigger("3")
        XCTAssertEqual([
            merge(("1", nil)),
            merge(("1", "2")),
            merge(("2", "2"))
        ], result.map(merge))
        b.dispose()
    }
}





