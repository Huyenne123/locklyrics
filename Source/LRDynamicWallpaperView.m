#import "LRDynamicWallpaperView.h"
#import "LRColorExtractor.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <simd/simd.h>
#import <stdlib.h>

#define LR_COLOR_SLOTS 8

typedef struct {
    int32_t point_count;
    float bias;
    float power;
    float noise;
    simd_float2 points[LR_COLOR_SLOTS];
    simd_float4 colors[LR_COLOR_SLOTS];
} LRMeshUniforms;

static NSString * const kLRMeshMetalShaderSource = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"#define COLOR_SLOTS 8\n"
"#define PI_F 3.14159265359f\n"
"\n"
"typedef struct {\n"
"    int32_t point_count;\n"
"    float bias;\n"
"    float power;\n"
"    float noise;\n"
"    float2 points[COLOR_SLOTS];\n"
"    float4 colors[COLOR_SLOTS];\n"
"} Uniforms;\n"
"\n"
"float2 lr_hash23(float3 p3) {\n"
"    p3 = fract(p3 * float3(443.897f, 441.423f, 0.0973f));\n"
"    p3 += dot(p3, p3.yzx + 19.19f);\n"
"    return fract((p3.xx + p3.yz) * p3.zy);\n"
"}\n"
"\n"
"float3 lr_lab_to_xyz(float3 lab) {\n"
"    float y = (lab.x + 16.0f) / 116.0f;\n"
"    float x = lab.y / 500.0f + y;\n"
"    float z = y - lab.z / 200.0f;\n"
"    float x3 = x * x * x;\n"
"    float y3 = y * y * y;\n"
"    float z3 = z * z * z;\n"
"    x = (x3 > 0.008856f) ? x3 : ((x - 0.137931034f) / 7.787f);\n"
"    y = (y3 > 0.008856f) ? y3 : ((y - 0.137931034f) / 7.787f);\n"
"    z = (z3 > 0.008856f) ? z3 : ((z - 0.137931034f) / 7.787f);\n"
"    return float3(95.047f * x, 100.000f * y, 108.883f * z);\n"
"}\n"
"\n"
"float3 lr_xyz_to_rgb(float3 xyz) {\n"
"    float x = xyz.x * 0.01f;\n"
"    float y = xyz.y * 0.01f;\n"
"    float z = xyz.z * 0.01f;\n"
"    float r = x *  3.2406f + y * -1.5372f + z * -0.4986f;\n"
"    float g = x * -0.9689f + y *  1.8758f + z *  0.0415f;\n"
"    float b = x *  0.0557f + y * -0.2040f + z *  1.0570f;\n"
"    r = (r > 0.0031308f) ? (1.055f * pow(max(r, 0.0f), 0.41666667f) - 0.055f) : (12.92f * r);\n"
"    g = (g > 0.0031308f) ? (1.055f * pow(max(g, 0.0f), 0.41666667f) - 0.055f) : (12.92f * g);\n"
"    b = (b > 0.0031308f) ? (1.055f * pow(max(b, 0.0f), 0.41666667f) - 0.055f) : (12.92f * b);\n"
"    return float3(r, g, b);\n"
"}\n"
"\n"
"kernel void lr_blend_colors(texture2d<float, access::write> output [[texture(0)]],\n"
"                            constant Uniforms &uniforms [[buffer(0)]],\n"
"                            uint2 gid [[thread_position_in_grid]]) {\n"
"    int width = (int)output.get_width();\n"
"    int height = (int)output.get_height();\n"
"    if ((int)gid.x >= width || (int)gid.y >= height) return;\n"
"    if (width <= 0 || height <= 0) return;\n"
"\n"
"    float invW = 1.0f / (float)width;\n"
"    float aspect = (float)height * invW;\n"
"    float2 n = lr_hash23(float3(float2(gid) * invW, 0.0f));\n"
"    float2 uv = (float2(gid) + float2(sin(n.x * 2.0f * PI_F), sin(n.y * 2.0f * PI_F)) * uniforms.noise) * invW;\n"
"\n"
"    float total = 0.0f;\n"
"    float weights[COLOR_SLOTS];\n"
"    int count = clamp(uniforms.point_count, 1, COLOR_SLOTS);\n"
"    for (int i = 0; i < count; i++) {\n"
"        float2 p = uniforms.points[i] * float2(1.0f, aspect);\n"
"        float dist = length(uv - p);\n"
"        float w = 1.0f / (uniforms.bias + pow(dist, uniforms.power));\n"
"        weights[i] = w;\n"
"        total += w;\n"
"    }\n"
"\n"
"    float4 lab = float4(0.0f);\n"
"    float invTotal = (total > 0.0f) ? (1.0f / total) : 0.0f;\n"
"    for (int i = 0; i < count; i++) {\n"
"        lab += uniforms.colors[i] * (weights[i] * invTotal);\n"
"    }\n"
"\n"
"    float3 rgb = lr_xyz_to_rgb(lr_lab_to_xyz(lab.xyz));\n"
"    output.write(clamp(float4(rgb, lab.w), 0.0f, 1.0f), gid);\n"
"}\n";

static simd_float4 lrColorToLAB4(UIColor *color) {
    CGFloat r = 0.08, g = 0.16, b = 0.24, a = 1.0;
    if (color) {
        if (![color getRed:&r green:&g blue:&b alpha:&a]) {
            CGFloat white = 0.15;
            if ([color getWhite:&white alpha:&a]) {
                r = g = b = white;
            }
        }
    }

    // sRGB -> Linear RGB
    double lr = (r <= 0.04045) ? (r / 12.92) : pow((r + 0.055) / 1.055, 2.4);
    double lg = (g <= 0.04045) ? (g / 12.92) : pow((g + 0.055) / 1.055, 2.4);
    double lb = (b <= 0.04045) ? (b / 12.92) : pow((b + 0.055) / 1.055, 2.4);

    // Linear RGB -> XYZ (D65)
    double x = (lr * 0.4124564 + lg * 0.3575761 + lb * 0.1804375) * 100.0 / 95.047;
    double y = (lr * 0.2126729 + lg * 0.7151522 + lb * 0.0721750) * 100.0 / 100.000;
    double z = (lr * 0.0193339 + lg * 0.1191920 + lb * 0.9503041) * 100.0 / 108.883;

    double fx = (x > 0.008856) ? cbrt(x) : (7.787 * x + 16.0 / 116.0);
    double fy = (y > 0.008856) ? cbrt(y) : (7.787 * y + 16.0 / 116.0);
    double fz = (z > 0.008856) ? cbrt(z) : (7.787 * z + 16.0 / 116.0);

    float L = (float)(116.0 * fy - 16.0);
    float A = (float)(500.0 * (fx - fy));
    float B = (float)(200.0 * (fy - fz));
    return simd_make_float4(L, A, B, (float)a);
}

@interface LRWeakDisplayLinkProxy : NSObject
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL selector;
- (instancetype)initWithTarget:(id)target selector:(SEL)selector;
- (void)handleTick:(CADisplayLink *)link;
@end

@implementation LRWeakDisplayLinkProxy
- (instancetype)initWithTarget:(id)target selector:(SEL)selector {
    self = [super init];
    if (self) {
        _target = target;
        _selector = selector;
    }
    return self;
}

- (void)handleTick:(CADisplayLink *)link {
    id strongTarget = self.target;
    if (strongTarget && [strongTarget respondsToSelector:self.selector]) {
        ((void (*)(id, SEL, id))[strongTarget methodForSelector:self.selector])(strongTarget, self.selector, link);
    }
}
@end

@interface LRDynamicWallpaperView () {
    simd_float4 _currentColors[LR_COLOR_SLOTS];
    simd_float4 _targetColors[LR_COLOR_SLOTS];
    float _phaseX[LR_COLOR_SLOTS];
    float _phaseY[LR_COLOR_SLOTS];
    float _freqX[LR_COLOR_SLOTS];
    float _freqY[LR_COLOR_SLOTS];
    double _elapsedPhase;
}

@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLComputePipelineState> pipelineState;
@property (nonatomic, assign) BOOL metalReady;
@property (nonatomic, strong) CAGradientLayer *fallbackGradientLayer;
@property (nonatomic, strong) NSArray<UIColor *> *fallbackColors;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval lastTickTimestamp;
@property (nonatomic, assign) CFTimeInterval lastRenderTimestamp;

@end

@implementation LRDynamicWallpaperView

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];

        _renderScale = 0.25;
        _frameLimit = 30;
        _speed = 0.60;
        _transitionSpeed = 2.5;
        _noiseAmount = 12.0;
        _animating = NO;
        _elapsedPhase = 0.0;

        static const float initPX[LR_COLOR_SLOTS] = { 0.3f, 1.8f, 3.1f, 4.4f, 0.9f, 2.5f, 3.9f, 5.2f };
        static const float initPY[LR_COLOR_SLOTS] = { 1.1f, 2.9f, 4.2f, 0.6f, 3.4f, 5.0f, 1.7f, 2.3f };
        static const float initFX[LR_COLOR_SLOTS] = { 0.41f, 0.53f, 0.37f, 0.61f, 0.47f, 0.33f, 0.59f, 0.43f };
        static const float initFY[LR_COLOR_SLOTS] = { 0.51f, 0.39f, 0.57f, 0.43f, 0.63f, 0.49f, 0.35f, 0.55f };
        for (int i = 0; i < LR_COLOR_SLOTS; i++) {
            _phaseX[i] = initPX[i];
            _phaseY[i] = initPY[i];
            _freqX[i] = initFX[i];
            _freqY[i] = initFY[i];
        }

        [self setupMetalPipeline];
        [self setColors:[LRColorExtractor defaultPalette] animated:NO];
    }
    return self;
}

- (void)dealloc {
    [self stopDisplayLink];
}

- (void)setupMetalPipeline {
    static id<MTLDevice> sharedDevice = nil;
    static id<MTLCommandQueue> sharedQueue = nil;
    static id<MTLComputePipelineState> sharedPipeline = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = dev ? [dev newCommandQueue] : nil;
        if (dev && queue) {
            NSError *libErr = nil;
            id<MTLLibrary> lib = [dev newLibraryWithSource:kLRMeshMetalShaderSource options:nil error:&libErr];
            id<MTLFunction> fn = lib ? [lib newFunctionWithName:@"lr_blend_colors"] : nil;
            NSError *pipeErr = nil;
            id<MTLComputePipelineState> pipe = fn ? [dev newComputePipelineStateWithFunction:fn error:&pipeErr] : nil;
            if (pipe) {
                sharedDevice = dev;
                sharedQueue = queue;
                sharedPipeline = pipe;
            }
        }
    });

    if (sharedPipeline && sharedDevice && sharedQueue) {
        _device = sharedDevice;
        _commandQueue = sharedQueue;
        _pipelineState = sharedPipeline;
        _metalReady = YES;

        CAMetalLayer *ml = (CAMetalLayer *)self.layer;
        ml.device = sharedDevice;
        ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        if (cs) {
            ml.colorspace = cs;
            CGColorSpaceRelease(cs);
        }
        ml.framebufferOnly = NO;
        ml.opaque = NO;
        ml.presentsWithTransaction = NO;
        ml.allowsNextDrawableTimeout = NO;
        ml.actions = @{
            @"position": [NSNull null],
            @"bounds": [NSNull null],
            @"frame": [NSNull null],
            @"contents": [NSNull null]
        };
        return;
    }

    // Fallback CAGradientLayer if Metal compute pipeline cannot be initialized
    _metalReady = NO;
    _fallbackGradientLayer = [CAGradientLayer layer];
    _fallbackGradientLayer.startPoint = CGPointMake(0.15, 0.0);
    _fallbackGradientLayer.endPoint = CGPointMake(0.85, 1.0);
    _fallbackGradientLayer.frame = self.bounds;
    [self.layer addSublayer:_fallbackGradientLayer];
}

#pragma mark - Public API & Properties

- (void)setRenderScale:(CGFloat)renderScale {
    CGFloat clamped = MAX(0.10, MIN(1.0, renderScale));
    if (fabs(_renderScale - clamped) < 0.001) return;
    _renderScale = clamped;
    [self updateDrawableSize];
}

- (void)setFrameLimit:(NSInteger)frameLimit {
    NSInteger valid = (frameLimit == 15 || frameLimit == 30 || frameLimit == 60) ? frameLimit : 30;
    if (_frameLimit == valid) return;
    _frameLimit = valid;
    if (self.displayLink) {
        self.displayLink.preferredFramesPerSecond = valid;
    }
}

- (void)setSpeed:(CGFloat)speed {
    _speed = MAX(0.0, MIN(2.0, speed));
}

- (void)setAnimating:(BOOL)animating {
    if (_animating == animating) return;
    _animating = animating;
    [self updateDisplayLinkState];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self updateDisplayLinkState];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateDrawableSize];
    [self updateDisplayLinkState];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.fallbackGradientLayer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.fallbackGradientLayer.frame = self.bounds;
        [CATransaction commit];
    }
    [self updateDrawableSize];
    if (self.window && !self.hidden) {
        [self renderSingleFrame];
    }
}

- (void)setColors:(NSArray<UIColor *> *)colors animated:(BOOL)animated {
    NSArray<UIColor *> *palette = (colors && colors.count > 0) ? colors : [LRColorExtractor defaultPalette];
    NSUInteger count = palette.count;

    for (int i = 0; i < LR_COLOR_SLOTS; i++) {
        UIColor *c = palette[(NSUInteger)i % count];
        simd_float4 lab = lrColorToLAB4(c);
        _targetColors[i] = lab;
        if (!animated || !self.animating) {
            _currentColors[i] = lab;
        }
    }

    if (!self.metalReady && self.fallbackGradientLayer) {
        NSMutableArray *cgColors = [NSMutableArray arrayWithCapacity:3];
        for (NSUInteger idx = 0; idx < 3; idx++) {
            UIColor *c = palette[idx % count];
            [cgColors addObject:(id)c.CGColor];
        }
        self.fallbackColors = palette;
        if (animated) {
            CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"colors"];
            anim.duration = 0.65;
            anim.fillMode = kCAFillModeForwards;
            [self.fallbackGradientLayer addAnimation:anim forKey:@"colorsTransition"];
        }
        self.fallbackGradientLayer.colors = cgColors;
        return;
    }

    if (self.window && !self.hidden && (!animated || !self.animating)) {
        [self renderSingleFrame];
    }
}

#pragma mark - Drawable & DisplayLink Lifecycle

- (void)updateDrawableSize {
    if (!self.metalReady) return;
    CAMetalLayer *ml = (CAMetalLayer *)self.layer;
    CGRect b = self.bounds;
    if (CGRectIsEmpty(b) || b.size.width <= 0.0 || b.size.height <= 0.0) {
        return;
    }

    CGFloat scale = (self.window.screen.scale > 0.0) ? self.window.screen.scale : [UIScreen mainScreen].scale;
    CGFloat w = round(b.size.width * scale * self.renderScale);
    CGFloat h = round(b.size.height * scale * self.renderScale);
    w = MAX(16.0, MIN(2048.0, w));
    h = MAX(16.0, MIN(2048.0, h));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (fabs(ml.drawableSize.width - w) > 0.5 || fabs(ml.drawableSize.height - h) > 0.5) {
        ml.drawableSize = CGSizeMake(w, h);
    }
    [CATransaction commit];
}

- (void)updateDisplayLinkState {
    BOOL shouldRun = self.metalReady && self.animating && (self.window != nil) && !self.hidden;
    if (shouldRun) {
        [self startDisplayLink];
    } else {
        [self stopDisplayLink];
    }
}

- (void)startDisplayLink {
    if (self.displayLink) {
        self.displayLink.preferredFramesPerSecond = self.frameLimit;
        return;
    }
    LRWeakDisplayLinkProxy *proxy = [[LRWeakDisplayLinkProxy alloc] initWithTarget:self selector:@selector(onDisplayLinkTick:)];
    self.displayLink = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(handleTick:)];
    self.displayLink.preferredFramesPerSecond = self.frameLimit;
    self.lastTickTimestamp = 0.0;
    self.lastRenderTimestamp = 0.0;
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopDisplayLink {
    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
    self.lastTickTimestamp = 0.0;
    self.lastRenderTimestamp = 0.0;
}

- (void)onDisplayLinkTick:(CADisplayLink *)link {
    if (!self.animating || !self.window || self.hidden) {
        [self stopDisplayLink];
        return;
    }

    CFTimeInterval now = link.timestamp;
    if (self.lastRenderTimestamp > 0.0) {
        double minInterval = (1.0 / (double)MAX(15, self.frameLimit)) * 0.9;
        if ((now - self.lastRenderTimestamp) < minInterval) {
            return;
        }
    }

    double dt = (self.lastTickTimestamp > 0.0) ? (now - self.lastTickTimestamp) : (1.0 / (double)MAX(15, self.frameLimit));
    dt = MIN(0.1, MAX(0.001, dt));
    self.lastTickTimestamp = now;
    self.lastRenderTimestamp = now;

    [self renderFrameWithDelta:dt];
}

#pragma mark - Metal Render

- (void)renderSingleFrame {
    if (!self.metalReady || !self.window || self.hidden) return;
    if (!self.animating) {
        for (int i = 0; i < LR_COLOR_SLOTS; i++) {
            _currentColors[i] = _targetColors[i];
        }
    }
    [self renderFrameWithDelta:0.0];
}

- (void)renderFrameWithDelta:(double)dt {
    if (!self.metalReady || !self.pipelineState || !self.commandQueue) return;

    CAMetalLayer *ml = (CAMetalLayer *)self.layer;
    if (ml.drawableSize.width < 2.0 || ml.drawableSize.height < 2.0) {
        [self updateDrawableSize];
        if (ml.drawableSize.width < 2.0 || ml.drawableSize.height < 2.0) return;
    }

    if (dt > 0.0) {
        _elapsedPhase += dt * (double)self.speed * 0.45;
        float lerpT = (float)MIN(1.0, dt * (double)self.transitionSpeed);
        for (int i = 0; i < LR_COLOR_SLOTS; i++) {
            _currentColors[i] = simd_mix(_currentColors[i], _targetColors[i], lerpT);
        }
    }

    LRMeshUniforms uniforms;
    uniforms.point_count = LR_COLOR_SLOTS;
    uniforms.bias = 0.015f;
    uniforms.power = 3.2f;
    uniforms.noise = (float)self.noiseAmount;

    for (int i = 0; i < LR_COLOR_SLOTS; i++) {
        double t = _elapsedPhase;
        float px = 0.50f + 0.42f * sinf((float)(t * _freqX[i] + _phaseX[i]));
        float py = 0.50f + 0.42f * cosf((float)(t * _freqY[i] + _phaseY[i]));
        uniforms.points[i] = simd_make_float2(MAX(0.05f, MIN(0.95f, px)), MAX(0.05f, MIN(0.95f, py)));
        uniforms.colors[i] = _currentColors[i];
    }

    id<CAMetalDrawable> drawable = [ml nextDrawable];
    if (!drawable || !drawable.texture) return;

    id<MTLCommandBuffer> cmdBuf = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [cmdBuf computeCommandEncoder];
    if (!encoder) return;

    [encoder setComputePipelineState:self.pipelineState];
    [encoder setTexture:drawable.texture atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(LRMeshUniforms) atIndex:0];

    NSUInteger w = self.pipelineState.threadExecutionWidth;
    if (w == 0) w = 8;
    NSUInteger h = self.pipelineState.maxTotalThreadsPerThreadgroup / w;
    if (h == 0) h = 1;
    if (h > 16) h = 16;

    NSUInteger texW = drawable.texture.width;
    NSUInteger texH = drawable.texture.height;
    MTLSize threadgroupSize = MTLSizeMake(w, h, 1);
    MTLSize threadgroups = MTLSizeMake((texW + w - 1) / w, (texH + h - 1) / h, 1);

    [encoder dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadgroupSize];
    [encoder endEncoding];

    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
}

@end
