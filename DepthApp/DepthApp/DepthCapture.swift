//  DepthCapture.swift
//  AVCamPhotoFilter
//
//  Created by Eyal Fink on 07/04/2018.
//  Copyright © 2018 Resonai. All rights reserved.
//
// Capture the depth pixelBuffer into a compress file.
// This is very hacky and there are lots of TODOs but instead we need to replace
// it with a much better compression (video compression)....

import AVFoundation
import Foundation
import Compression


class DepthCapture {
    let kErrorDomain = "DepthCapture"
    let maxNumberOfFrame = 250
    lazy var bufferSize = 640 * 480 * 2 * maxNumberOfFrame  // maxNumberOfFrame frames
    var dstBuffer: UnsafeMutablePointer<UInt8>?
    var frameCount: Int64 = 0
    var outputURL: URL?
    var compresserPtr: UnsafeMutablePointer<compression_stream>?
    var file: FileHandle?
    
    // All operations handling the compresser oobjects are done on the
    // porcessingQ so they will happen sequentially
    var processingQ = DispatchQueue(label: "compression",
                                    qos: .userInteractive)
    
    
    func reset() {
        frameCount = 0
        outputURL = nil
        if self.compresserPtr != nil {
            //free(compresserPtr!.pointee.dst_ptr)
            compression_stream_destroy(self.compresserPtr!)
            self.compresserPtr = nil
        }
        if self.file != nil {
            self.file!.closeFile()
            self.file = nil
        }
    }
    func prepareForRecording() {
        reset()
        // Create the output zip file, remove old one if exists
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as NSString
        self.outputURL = URL(fileURLWithPath: documentsPath.appendingPathComponent("Depth"))
        FileManager.default.createFile(atPath: self.outputURL!.path, contents: nil, attributes: nil)
        self.file = FileHandle(forUpdatingAtPath: self.outputURL!.path)
        if self.file == nil {
            NSLog("Cannot create file at: \(self.outputURL!.path)")
            return
        }
        
        // Init the compression object
        compresserPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        compression_stream_init(compresserPtr!, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        compresserPtr!.pointee.dst_ptr = dstBuffer!
        //defer { free(bufferPtr) }
        compresserPtr!.pointee.dst_size = bufferSize
        
        
    }
    func flush() {
        //let data = Data(bytesNoCopy: compresserPtr!.pointee.dst_ptr, count: bufferSize, deallocator: .none)
        let nBytes = bufferSize - compresserPtr!.pointee.dst_size
        print("Writing \(nBytes)")
        let data = Data(bytesNoCopy: dstBuffer!, count: nBytes, deallocator: .none)
        self.file?.write(data)
    }
    
    func startRecording() throws {
        processingQ.async {
            self.prepareForRecording()
        }
    }
    func addPixelBuffers(pixelBuffer: CVPixelBuffer) {
        processingQ.async {
            if self.frameCount >= self.maxNumberOfFrame {
                // TODO now!! flush when needed!!!
                print("MAXED OUT")
                return
            }
            
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            let add : UnsafeMutableRawPointer = CVPixelBufferGetBaseAddress(pixelBuffer)!
            self.compresserPtr!.pointee.src_ptr = UnsafePointer<UInt8>(add.assumingMemoryBound(to: UInt8.self))
            let height = CVPixelBufferGetHeight(pixelBuffer)
            self.compresserPtr!.pointee.src_size = CVPixelBufferGetBytesPerRow(pixelBuffer) * height
            let flags = Int32(0)
            let compression_status = compression_stream_process(self.compresserPtr!, flags)
            if compression_status != COMPRESSION_STATUS_OK {
                NSLog("Buffer compression retured: \(compression_status)")
                return
            }
            if self.compresserPtr!.pointee.src_size != 0 {
                NSLog("Compression lib didn't eat all data: \(compression_status)")
                return
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            // TODO(eyal): flush when needed!!!
            self.frameCount += 1
            print("handled \(self.frameCount) buffers")
        }
    }
    func finishRecording(success: @escaping ((URL) -> Void)) throws {
        processingQ.async {
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            self.compresserPtr!.pointee.src_size = 0
            //compresserPtr!.pointee.src_ptr = UnsafePointer<UInt8>(0)
            let compression_status = compression_stream_process(self.compresserPtr!, flags)
            if compression_status != COMPRESSION_STATUS_END {
                NSLog("ERROR: Finish failed. compression retured: \(compression_status)")
                return
            }
            self.flush()
            DispatchQueue.main.sync {
                success(self.outputURL!)
            }
            self.reset()
        }
    }
}
