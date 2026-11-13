#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

#include "imgui.h"
#include "imgui_impl_metal.h"

@interface GBRDemoController : UIViewController <MTKViewDelegate>
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, assign) BOOL initialized;
@end

@implementation GBRDemoController {
    bool showDemo;
    bool overlayEnabled;
    float intensity;
    int selectedTab;
}

- (void)loadView {
    self.device = MTLCreateSystemDefaultDevice();
    if (!self.device) {
        self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
        return;
    }

    MTKView *view = [[MTKView alloc] initWithFrame:UIScreen.mainScreen.bounds
                                           device:self.device];
    view.clearColor = MTLClearColorMake(0.035, 0.045, 0.065, 1.0);
    view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    view.framebufferOnly = NO;
    view.preferredFramesPerSecond = 60;
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    if (![self.view isKindOfClass:MTKView.class]) return;
    MTKView *view = (MTKView *)self.view;
    self.commandQueue = [self.device newCommandQueue];
    view.delegate = self;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();

    ImGuiStyle &style = ImGui::GetStyle();
    style.WindowRounding = 12.0f;
    style.FrameRounding = 7.0f;
    style.GrabRounding = 7.0f;
    style.WindowPadding = ImVec2(16.0f, 14.0f);

    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.DisplaySize = ImVec2(view.bounds.size.width, view.bounds.size.height);
    io.DisplayFramebufferScale = ImVec2(view.contentScaleFactor, view.contentScaleFactor);

    ImGui_ImplMetal_Init(self.device);
    self.initialized = YES;
}

- (void)drawInMTKView:(MTKView *)view {
    if (!self.initialized) return;

    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(view.bounds.size.width, view.bounds.size.height);
    io.DisplayFramebufferScale = ImVec2(view.contentScaleFactor, view.contentScaleFactor);
    io.DeltaTime = 1.0f / (float)MAX(view.preferredFramesPerSecond, 1);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    ImGui_ImplMetal_NewFrame(pass);
    ImGui::NewFrame();

    ImGui::SetNextWindowSize(ImVec2(330, 260), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(18, 40), ImGuiCond_FirstUseEver);
    ImGui::Begin("Metal UI Demo", nullptr, ImGuiWindowFlags_NoCollapse);
    ImGui::TextColored(ImVec4(0.35f, 0.85f, 1.0f, 1.0f), "Standalone iOS sample");
    ImGui::Separator();

    if (ImGui::BeginTabBar("demo-tabs")) {
        if (ImGui::BeginTabItem("Display")) {
            ImGui::Checkbox("Overlay preview", &overlayEnabled);
            ImGui::SliderFloat("Intensity", &intensity, 0.0f, 1.0f, "%.2f");
            ImGui::Text("Frame rate: %.0f FPS", io.Framerate);
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("About")) {
            ImGui::TextWrapped("A self-contained ImGui + Metal rendering sample.");
            ImGui::TextWrapped("It does not inspect, modify, or hook another app.");
            ImGui::EndTabItem();
        }
        ImGui::EndTabBar();
    }

    if (overlayEnabled) {
        ImGui::Spacing();
        ImGui::Text("Preview enabled");
        ImGui::ProgressBar(intensity, ImVec2(-1, 0), "Demo");
    }
    ImGui::End();

    ImGui::Render();
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:pass];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, encoder);
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)dealloc {
    if (self.initialized) {
        ImGui_ImplMetal_Shutdown();
        ImGui::DestroyContext();
    }
}
@end

// The host app may call this exported factory from its own, authorized code.
extern "C" __attribute__((visibility("default")))
UIViewController *CreateStandaloneImGuiDemoController(void) {
    return [[GBRDemoController alloc] init];
}
