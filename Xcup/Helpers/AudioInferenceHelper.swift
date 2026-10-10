//
//  AudioInferenceHelper.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//


import Foundation
import TensorFlowLite

class AudioInferenceHelper {

    // MARK: - 模型参数
    private let SAMPLE_RATE = 16000
    private let INPUT_LENGTH = 32000 // 输入 2 秒音频数据
    private let EMBEDDING_SIZE = 1024

    private var yamnetInterpreter: Interpreter!
    private var classifierInterpreter: Interpreter!

    // YAMNet 的输出按形状认（最后一维 1024 是 embedding、521 是 AudioSet 分数），不写死下标；
    // 与 Android AudioInferenceHelper、bench/tools/audio_rescore.py 相同。输入是动态长度，invoke 之前输出张量还没有数据、
    // 取不到（TensorFlowLiteSwift 会抛 invokeInterpreterRequired），所以第一次推理之后认一次。
    // 找不到分数输出时 scoresOutput = -1，线索为 unknown（融合仲裁的行为与 v1 相同）。
    private var outputsResolved = false
    private var embeddingOutput = 1
    private var scoresOutput = -1

    init() {
        do {
            guard let yamnetPath = Bundle.main.path(forResource: "yamnet", ofType: "tflite"),
                  let classifierPath = Bundle.main.path(forResource: "yamnet_finetuned", ofType: "tflite") else {
                print("❌ 模型文件未找到")
                return
            }

            var options = Interpreter.Options()
            options.threadCount = 2

            // ① 创建 Interpreter
            yamnetInterpreter      = try Interpreter(modelPath: yamnetPath,      options: options)
            classifierInterpreter  = try Interpreter(modelPath: classifierPath,  options: options)

            // ② 先把可变维度改成我们需要的 [32000]
            try yamnetInterpreter.resizeInput(at: 0, to: [INPUT_LENGTH])

            // ③ 再分配 tensor 内存
            try yamnetInterpreter.allocateTensors()
            try classifierInterpreter.allocateTensors()

            print("✅ 音频模型初始化成功")
        } catch {
            print("❌ 初始化失败: \(error)")
        }
    }


    /// 执行一次音频推理流程：YAMNet → 分类器
    /// - Parameter audioBuffer: 长度为 32000 的 Float 数组（2 秒音频）
    /// - Returns: (类别索引, 置信度, 完整概率数组, AudioSet 分数)
    ///   probs 顺序为 [sex, oral, noise]；无效结果时 index = -1、probs 为空数组。
    ///   audioSet 是 YAMNet 自带的 AudioSet 521 类分数（各帧平均），给 AudioCue 判音频线索；拿不到时为空数组
    func predict(audioBuffer: [Float]) -> (index: Int, confidence: Float, probs: [Float], audioSet: [Float]) {
        guard audioBuffer.count == INPUT_LENGTH else {
            print("❌ 音频长度不正确，应为 32000，当前为 \(audioBuffer.count)")
            return (-1, 0, [], [])
        }

        do {
            let inputShape = try yamnetInterpreter.input(at: 0).shape.dimensions
            //print("🧪 当前 YAMNet 输入 shape = \(inputShape)")   // 应该看到 [32000]
            // 1. YAMNet 推理（输入 shape: [32000]）
            let yamnetInputData = toData(from: audioBuffer)
            //print("🧪 准备推理 YAMNet")
            // AudioSet 分数和 embedding 是同一次推理的两个输出，多取一个不用再跑一次模型
            try yamnetInterpreter.copy(yamnetInputData, toInputAt: 0)
            try yamnetInterpreter.invoke()
            //print("✅ YAMNet 推理完成")
            resolveOutputsIfNeeded()

            // YAMNet 输出 shape 为 [num_frames, 1024]
            let outputTensor = try yamnetInterpreter.output(at: embeddingOutput)
            let outputShape = outputTensor.shape.dimensions
            let outputData = outputTensor.data.toArray(type: Float32.self)
            let numFrames = outputShape[0]

            // 2. 平均输出特征
            var meanEmbedding = [Float](repeating: 0, count: EMBEDDING_SIZE)
            for i in 0..<numFrames {
                for j in 0..<EMBEDDING_SIZE {
                    meanEmbedding[j] += outputData[i * EMBEDDING_SIZE + j]
                }
            }
            for j in 0..<EMBEDDING_SIZE {
                meanEmbedding[j] /= Float(numFrames)
            }

            // 2b. AudioSet 分数同样各帧平均（拿不到时为空数组，不影响下面的分类）
            let audioSet = meanAudioSetScores()

            // 3. 分类器推理
            //let clsInputShape = try classifierInterpreter.input(at: 0).shape.dimensions
            //print("🧪 分类器输入 shape =", clsInputShape)
            let classifierInputData = toData(from: meanEmbedding)
            try classifierInterpreter.copy(classifierInputData, toInputAt: 0)
            try classifierInterpreter.invoke()

            let classOutput = try classifierInterpreter.output(at: 0)
            let scores = classOutput.data.toArray(type: Float32.self)

            if let maxIndex = scores.argmax() {
                let confidence = scores[maxIndex] // 概率分布中最大值
                //print("✅ 音频推理结果: 类别 \(maxIndex), 置信度 \(confidence)")
                return (maxIndex, confidence, scores, audioSet)
            } else {
                return (-1, 0, [], audioSet)
            }

        } catch {
            print("❌ 音频推理失败: \(error)")
            return (-1, 0, [], [])
        }
    }

    /// 第一次推理之后按形状认一次 YAMNet 的输出。某个输出张量还取不到时不认，下次推理再认。
    private func resolveOutputsIfNeeded() {
        if outputsResolved { return }
        var emb = -1
        var sc = -1
        for i in 0..<yamnetInterpreter.outputTensorCount {
            guard let dims = try? yamnetInterpreter.output(at: i).shape.dimensions else { return }
            let last = dims.last ?? -1
            if last == EMBEDDING_SIZE {
                emb = i
            } else if last == AudioCue.nClasses {
                sc = i
            }
        }
        if emb >= 0 { embeddingOutput = emb }
        scoresOutput = sc
        outputsResolved = true
        print("🎵 YAMNet 输出：embedding=\(embeddingOutput)，AudioSet 分数=\(scoresOutput)"
              + (sc < 0 ? "（模型没有 521 维分数输出，音频线索一直是未知）" : ""))
    }

    /// AudioSet 分数各帧平均：逐帧按顺序 Float 累加，最后除以帧数（与 embedding 的平均方式、Android 和
    /// audio_rescore.py 的离线重算相同，不用 vDSP）。没有分数输出或读取失败时返回空数组（线索为 unknown）。
    private func meanAudioSetScores() -> [Float] {
        guard scoresOutput >= 0,
              let tensor = try? yamnetInterpreter.output(at: scoresOutput),
              tensor.dataType == .float32 else { return [] }
        let n = AudioCue.nClasses
        let flat = tensor.data.toArray(type: Float32.self)
        let frames = flat.count / n                  // [帧, 521]：2 秒输入是 4 帧
        guard frames > 0, frames * n == flat.count else { return [] }
        var mean = [Float](repeating: 0, count: n)
        for f in 0..<frames {
            for j in 0..<n {
                mean[j] += flat[f * n + j]
            }
        }
        for j in 0..<n {
            mean[j] /= Float(frames)
        }
        return mean
    }

    func close() {
        yamnetInterpreter = nil
        classifierInterpreter = nil
    }
}

// MARK: - 输入数据类型
func toData(from array: [Float]) -> Data {
    return array.withUnsafeBufferPointer {
        Data(buffer: $0)
    }
}


// MARK: - Data 解析工具（转为 Float 数组）
extension Data {
    func toArray<T>(type: T.Type) -> [T] {
        return withUnsafeBytes {
            Array($0.bindMemory(to: type))
        }
    }
}

// MARK: - Argmax 工具
extension Array where Element == Float {
    func argmax() -> Int? {
        guard let max = self.max(), let idx = self.firstIndex(of: max) else { return nil }
        return idx
    }
}
