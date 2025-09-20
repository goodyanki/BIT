#include <metal_stdlib>
using namespace metal;

// MARK: - 数据结构定义

struct VertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 worldPosition;
};

struct UniformData {
    float flashOpacity;
    float hoverScale;
    float time;
    float4x4 transform;
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
};

struct BackgroundUniformData {
    float time;
    float2 resolution;
    float4 gradientColors[3];
};

struct SearchParameters {
    uint appCount;
    uint queryLength;
    float matchThreshold;
    float fuzzyThreshold;
};

struct GPUAppData {
    char name[128];
    char bundleID[128];
    uint index;
    uint nameLength;
    uint bundleIDLength;
    uint reserved;
};

struct SearchResult {
    uint appIndex;
    uint isMatch;
    uint matchType;  // 0: 精确, 1: 包含, 2: 模糊
    uint reserved;
};

// MARK: - 顶点着色器

vertex VertexOut icon_vertex_main(
    VertexIn in [[stage_in]],
    constant UniformData& uniforms [[buffer(1)]]
) {
    VertexOut out;
    
    // 应用悬停缩放
    float4 scaledPosition = in.position;
    scaledPosition.xy *= uniforms.hoverScale;
    
    // 应用变换矩阵
    out.worldPosition = uniforms.transform * scaledPosition;
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * out.worldPosition;
    out.texCoord = in.texCoord;
    
    return out;
}

vertex VertexOut background_vertex_main(
    VertexIn in [[stage_in]],
    constant BackgroundUniformData& uniforms [[buffer(1)]]
) {
    VertexOut out;
    out.position = in.position;
    out.texCoord = in.texCoord;
    out.worldPosition = in.position;
    return out;
}

vertex VertexOut effect_vertex_main(
    VertexIn in [[stage_in]],
    constant UniformData& uniforms [[buffer(1)]]
) {
    VertexOut out;
    out.position = in.position;
    out.texCoord = in.texCoord;
    out.worldPosition = uniforms.transform * in.position;
    return out;
}

// MARK: - 片段着色器

fragment float4 icon_fragment_main(
    VertexOut in [[stage_in]],
    constant UniformData& uniforms [[buffer(0)]],
    texture2d<float> iconTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    // 采样图标纹理
    float4 color = iconTexture.sample(textureSampler, in.texCoord);
    
    // 应用闪光效果
    float4 flashColor = float4(1.0, 1.0, 1.0, uniforms.flashOpacity);
    color = mix(color, flashColor, uniforms.flashOpacity);
    
    // 悬停时的微光效果
    float hoverGlow = smoothstep(0.98, 1.02, uniforms.hoverScale);
    if (hoverGlow > 0.0) {
        float2 center = float2(0.5, 0.5);
        float dist = distance(in.texCoord, center);
        float glowMask = 1.0 - smoothstep(0.3, 0.5, dist);
        float4 glowColor = float4(1.0, 1.0, 1.0, 0.3 * hoverGlow * glowMask);
        color = mix(color, glowColor, glowColor.a);
    }
    
    // 时间相关的微妙动画
    float pulse = sin(uniforms.time * 2.0) * 0.05 + 0.95;
    color.rgb *= pulse;
    
    return color;
}

fragment float4 background_fragment_main(
    VertexOut in [[stage_in]],
    constant BackgroundUniformData& uniforms [[buffer(0)]],
    texture2d<float> gradientTexture [[texture(0)]],
    texture2d<float> noiseTexture [[texture(1)]],
    sampler textureSampler [[sampler(0)]]
) {
    float2 uv = in.texCoord;
    float2 screenPos = (in.position.xy / uniforms.resolution) * 2.0 - 1.0;
    
    // 基础渐变
    float gradientFactor = length(screenPos) * 0.5;
    float4 gradient = mix(uniforms.gradientColors[0], uniforms.gradientColors[1], gradientFactor);
    gradient = mix(gradient, uniforms.gradientColors[2], gradientFactor * gradientFactor);
    
    // 动态噪声效果
    float2 noiseUV = uv * 4.0 + uniforms.time * 0.1;
    float noise = noiseTexture.sample(textureSampler, noiseUV).r;
    noise = (noise - 0.5) * 0.1; // 减少噪声强度
    
    // 动态波纹效果
    float wave1 = sin(screenPos.x * 10.0 + uniforms.time * 2.0) * 0.02;
    float wave2 = cos(screenPos.y * 8.0 + uniforms.time * 1.5) * 0.02;
    float waveEffect = wave1 + wave2;
    
    // 组合效果
    gradient.rgb += noise + waveEffect;
    gradient.rgb = saturate(gradient.rgb);
    
    return gradient;
}

fragment float4 effect_fragment_main(
    VertexOut in [[stage_in]],
    constant UniformData& uniforms [[buffer(0)]],
    texture2d<float> effectTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    float2 uv = in.texCoord;
    
    // 粒子效果或其他特殊效果
    float4 effect = effectTexture.sample(textureSampler, uv);
    
    // 时间动画
    float animation = sin(uniforms.time * 3.0) * 0.5 + 0.5;
    effect.a *= animation;
    
    return effect;
}

// MARK: - 计算着色器

// 并行字符串匹配
kernel void string_match_compute(
    constant GPUAppData* appData [[buffer(0)]],
    constant char* query [[buffer(1)]],
    device SearchResult* results [[buffer(2)]],
    constant SearchParameters& params [[buffer(3)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= params.appCount) {
        return;
    }
    
    // 初始化结果
    results[index].appIndex = index;
    results[index].isMatch = 0;
    results[index].matchType = 0;
    
    constant GPUAppData& app = appData[index];
    
    // 精确匹配检查 - 名称
    bool nameExactMatch = true;
    for (uint i = 0; i < params.queryLength && i < app.nameLength; i++) {
        if (app.name[i] != query[i]) {
            nameExactMatch = false;
            break;
        }
    }
    
    if (nameExactMatch && params.queryLength <= app.nameLength) {
        results[index].isMatch = 1;
        results[index].matchType = 0; // 精确匹配
        return;
    }
    
    // 包含匹配检查 - 名称
    bool nameContains = false;
    if (app.nameLength >= params.queryLength) {
        for (uint start = 0; start <= app.nameLength - params.queryLength; start++) {
            bool match = true;
            for (uint i = 0; i < params.queryLength; i++) {
                if (app.name[start + i] != query[i]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                nameContains = true;
                break;
            }
        }
    }
    
    if (nameContains) {
        results[index].isMatch = 1;
        results[index].matchType = 1; // 包含匹配
        return;
    }
    
    // Bundle ID 包含匹配检查
    bool bundleContains = false;
    if (app.bundleIDLength >= params.queryLength) {
        for (uint start = 0; start <= app.bundleIDLength - params.queryLength; start++) {
            bool match = true;
            for (uint i = 0; i < params.queryLength; i++) {
                if (app.bundleID[start + i] != query[i]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                bundleContains = true;
                break;
            }
        }
    }
    
    if (bundleContains) {
        results[index].isMatch = 1;
        results[index].matchType = 1; // 包含匹配
        return;
    }
}

// 模糊搜索
kernel void fuzzy_search_compute(
    constant GPUAppData* appData [[buffer(0)]],
    constant char* query [[buffer(1)]],
    device SearchResult* results [[buffer(2)]],
    constant SearchParameters& params [[buffer(3)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= params.appCount || results[index].isMatch == 1) {
        return; // 已经匹配的跳过
    }
    
    constant GPUAppData& app = appData[index];
    
    // 模糊匹配算法 - 检查查询字符是否按顺序出现在名称中
    uint queryPos = 0;
    for (uint i = 0; i < app.nameLength && queryPos < params.queryLength; i++) {
        if (app.name[i] == query[queryPos]) {
            queryPos++;
        }
    }
    
    if (queryPos == params.queryLength) {
        results[index].isMatch = 1;
        results[index].matchType = 2; // 模糊匹配
        return;
    }
    
    // Bundle ID 模糊匹配
    queryPos = 0;
    for (uint i = 0; i < app.bundleIDLength && queryPos < params.queryLength; i++) {
        if (app.bundleID[i] == query[queryPos]) {
            queryPos++;
        }
    }
    
    if (queryPos == params.queryLength) {
        results[index].isMatch = 1;
        results[index].matchType = 2; // 模糊匹配
    }
}

// 搜索评分计算
kernel void search_scoring_compute(
    constant GPUAppData* appData [[buffer(0)]],
    constant char* query [[buffer(1)]],
    constant SearchResult* results [[buffer(2)]],
    device float* scores [[buffer(3)]],
    uint index [[thread_position_in_grid]]
) {
    scores[index] = 0.0;
    
    if (results[index].isMatch == 0) {
        return;
    }
    
    constant GPUAppData& app = appData[index];
    float score = 0.0;
    
    // 根据匹配类型给分
    switch (results[index].matchType) {
        case 0: // 精确匹配
            score += 100.0;
            break;
        case 1: // 包含匹配
            score += 50.0;
            break;
        case 2: // 模糊匹配
            score += 25.0;
            break;
    }
    
    // 名称匹配优于Bundle ID匹配的额外加分逻辑
    // (这里简化处理，实际可以更复杂)
    
    // 苹果应用加分
    if (app.bundleIDLength > 10) {
        bool isAppleApp = true;
        const char applePrefix[] = "com.apple.";
        for (uint i = 0; i < 10; i++) {
            if (app.bundleID[i] != applePrefix[i]) {
                isAppleApp = false;
                break;
            }
        }
        if (isAppleApp) {
            score += 5.0;
        }
    }
    
    // 长度偏好 - 较短的名称获得轻微加分
    if (app.nameLength > 0) {
        score += (50.0 - min(50.0, float(app.nameLength))) * 0.1;
    }
    
    scores[index] = score;
}

// 并行排序 (简化版本 - 冒泡排序的并行化)
kernel void parallel_sort_compute(
    device SearchResult* results [[buffer(0)]],
    device float* scores [[buffer(1)]],
    constant uint& arraySize [[buffer(2)]],
    constant uint& step [[buffer(3)]],
    uint index [[thread_position_in_grid]]
) {
    uint i = index * 2 + (step % 2);
    
    if (i + 1 < arraySize) {
        if (scores[i] < scores[i + 1]) {
            // 交换元素
            float tempScore = scores[i];
            scores[i] = scores[i + 1];
            scores[i + 1] = tempScore;
            
            SearchResult tempResult = results[i];
            results[i] = results[i + 1];
            results[i + 1] = tempResult;
        }
    }
}

// 纹理处理计算着色器
kernel void texture_process_compute(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }
    
    // 读取输入像素
    float4 inputColor = inputTexture.read(gid);
    
    // 应用处理效果 (例如: 锐化, 模糊, 颜色调整等)
    float4 outputColor = inputColor;
    
    // 示例: 简单的锐化滤镜
    if (gid.x > 0 && gid.x < inputTexture.get_width() - 1 &&
        gid.y > 0 && gid.y < inputTexture.get_height() - 1) {
        
        float4 center = inputTexture.read(gid);
        float4 top = inputTexture.read(uint2(gid.x, gid.y - 1));
        float4 bottom = inputTexture.read(uint2(gid.x, gid.y + 1));
        float4 left = inputTexture.read(uint2(gid.x - 1, gid.y));
        float4 right = inputTexture.read(uint2(gid.x + 1, gid.y));
        
        // 拉普拉斯算子进行锐化
        outputColor = center * 5.0 - (top + bottom + left + right);
        outputColor = saturate(outputColor);
    }
    
    // 写入输出纹理
    outputTexture.write(outputColor, gid);
}

// 高级并行搜索 (改进版本)
kernel void parallel_search_compute(
    constant GPUAppData* appData [[buffer(0)]],
    constant char* query [[buffer(1)]],
    device SearchResult* results [[buffer(2)]],
    device float* scores [[buffer(3)]],
    constant SearchParameters& params [[buffer(4)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= params.appCount) {
        return;
    }
    
    // 初始化
    results[index].appIndex = index;
    results[index].isMatch = 0;
    results[index].matchType = 0;
    scores[index] = 0.0;
    
    constant GPUAppData& app = appData[index];
    float score = 0.0;
    bool matched = false;
    uint matchType = 0;
    
    // 1. 精确前缀匹配 (最高优先级)
    if (params.queryLength <= app.nameLength) {
        bool prefixMatch = true;
        for (uint i = 0; i < params.queryLength; i++) {
            if (app.name[i] != query[i]) {
                prefixMatch = false;
                break;
            }
        }
        if (prefixMatch) {
            matched = true;
            matchType = 0;
            score = 100.0;
        }
    }
    
    // 2. 包含匹配
    if (!matched && app.nameLength >= params.queryLength) {
        for (uint start = 0; start <= app.nameLength - params.queryLength; start++) {
            bool substringMatch = true;
            for (uint i = 0; i < params.queryLength; i++) {
                if (app.name[start + i] != query[i]) {
                    substringMatch = false;
                    break;
                }
            }
            if (substringMatch) {
                matched = true;
                matchType = 1;
                score = 50.0 + (start == 0 ? 20.0 : 0.0); // 开头匹配加分
                break;
            }
        }
    }
    
    // 3. Bundle ID 匹配
    if (!matched && app.bundleIDLength >= params.queryLength) {
        for (uint start = 0; start <= app.bundleIDLength - params.queryLength; start++) {
            bool bundleMatch = true;
            for (uint i = 0; i < params.queryLength; i++) {
                if (app.bundleID[start + i] != query[i]) {
                    bundleMatch = false;
                    break;
                }
            }
            if (bundleMatch) {
                matched = true;
                matchType = 1;
                score = 30.0;
                break;
            }
        }
    }
    
    // 4. 模糊匹配
    if (!matched) {
        uint queryPos = 0;
        for (uint i = 0; i < app.nameLength && queryPos < params.queryLength; i++) {
            if (app.name[i] == query[queryPos]) {
                queryPos++;
            }
        }
        if (queryPos == params.queryLength) {
            matched = true;
            matchType = 2;
            score = 15.0;
        }
    }
    
    if (matched) {
        results[index].isMatch = 1;
        results[index].matchType = matchType;
        
        // 额外评分因子
        // 苹果应用加分
        if (app.bundleIDLength >= 10) {
            bool isAppleApp = true;
            const char applePrefix[] = "com.apple.";
            for (uint i = 0; i < 10; i++) {
                if (app.bundleID[i] != applePrefix[i]) {
                    isAppleApp = false;
                    break;
                }
            }
            if (isAppleApp) {
                score += 5.0;
            }
        }
        
        // 名称长度因子
        if (app.nameLength > 0 && app.nameLength < 20) {
            score += (20.0 - float(app.nameLength)) * 0.2;
        }
        
        scores[index] = score;
    }
}
