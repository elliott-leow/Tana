/* Exercise the production layout/renderer with deterministic OS boundaries.
 * No Accessibility permission, real windows, or running daemon are needed. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdio.h>
#include "../src/strip_columns.h"

#define VIEW_STRIP 1
#define VIEW_IS_DIRTY 1
#define LAYER_AUTO 0
#define LAYER_BELOW -1
#define LAYER_NORMAL 0
#define MOUSE_MODE_MOVE 1
#define MOUSE_MODE_RESIZE 2
#define HANDLE_LEFT 1
#define HANDLE_RIGHT 2
#define HANDLE_TOP 4
#define HANDLE_BOTTOM 8
#define WINDOW_MINIMIZE 1
#define WINDOW_FULLSCREEN 2
#define table_for(declaration,table,body) for(int slot=0;slot<4;slot++) { declaration=&windows[slot]; body; }
#define AX_ENHANCED_UI_WORKAROUND(ref, body) do { (void)(ref); body; } while(0)
struct area { double x,y,w,h; };
struct application { int ref; bool is_hidden; };
struct window {
    uint32_t id; struct application *application;
    CGRect frame,strip_last_frame;
    uint64_t strip_column;
    double strip_min_width;
    double strip_weight,strip_width,strip_height,strip_world_x,strip_world_y;
    double strip_from_x,strip_from_y,strip_from_width,strip_from_height;
    double strip_vel_x,strip_vel_y,strip_vel_width,strip_vel_height;
    double strip_start,strip_last_offset,strip_size_sent_at;
    bool strip_initialized,strip_full_width,strip_size_pending,strip_tab_parked;
    int layer;
    bool floating,strip_float_animating,strip_close_pending;
    CGRect strip_float_from,strip_float_last,strip_float_target;
    double strip_float_start,strip_close_start;
    float strip_close_alpha;
    double strip_pop_start; int strip_pop; bool strip_pop_scaled,strip_close_scaled,strip_close_ghost;
};
struct window_node { int window_count; uint32_t window_list[1]; struct window_node *next; struct area area; };
struct view { int layout,window_gap; struct window_node *root; double strip_offset; bool strip_scrolling; };
static struct { int unused; } g_window_manager;
static struct { struct window *window; CGPoint down_location; CGRect window_frame; int current_action,direction; } g_mouse_state;
static int g_connection;
static bool hwm_ready=true,hwm_paused,hwm_overview_active,hwm_state_pending,hwm_backend_ok=true;
static bool __pending_gesture;
static uint32_t hwm_drag_window,hwm_close_source,hwm_close_target,hwm_feedback_focus_id;
static double hwm_duration=.24,hwm_close_screen_x,hwm_close_time,hwm_last_input;
static uint64_t hwm_move_failures,hwm_resize_operations;
static struct window windows[4];
static struct window_node nodes[4];
static struct application application;
static struct view view;
static CGRect actual[4];
static double clock_now=10;
static int ax_calls,moves,disable_calls,update_depth;
static bool move_fails;
static float alphas[4];
static int close_calls;
static double hwm_now(void) { return clock_now; }
static double horizontal_ease(double p) { return hstrip_ease(p); }
static void hwm_wake(void) {}
static CGRect hwm_bounds(struct view *v) { (void)v; return CGRectMake(12,51,1200,900); }
static double hwm_offset(struct view *v,double now) { (void)now; return v->strip_offset; }
static void hwm_scroll(struct view *v,double x,bool animate) { (void)animate; v->strip_offset=x; }
static struct window_node *window_node_find_first_leaf(struct window_node *n) { return n; }
static struct window_node *window_node_find_next_leaf(struct window_node *n) { return n->next; }
static struct window *window_manager_find_window(void *manager,uint32_t id) { (void)manager; return id>=1 && id<=4 ? &windows[id-1] : NULL; }
static struct view *window_manager_find_managed_window(void *manager,struct window *w) { (void)manager; return w->floating?NULL:&view; }
static bool window_check_flag(struct window *w,int flag) { (void)w; (void)flag; return false; }
static CGError SLSGetWindowAlpha(int connection,uint32_t id,float *alpha) { (void)connection; *alpha=alphas[id-1]; return kCGErrorSuccess; }
static double fade_duration[4];
static bool scripting_addition_set_opacity(uint32_t id,float alpha,double duration) { fade_duration[id-1]=duration; alphas[id-1]=alpha; return true; }
static int scale_calls;
static bool scripting_addition_scale_window(uint32_t id,float x,float y,float w,float h) { (void)id; (void)x; (void)y; (void)w; (void)h; ++scale_calls; return true; }
static bool window_manager_close_window(struct window *w) { (void)w; ++close_calls; return false; }
static struct window_node *view_find_window_node(struct view *v,uint32_t id) { for(struct window_node *n=v->root;n;n=n->next) if(n->window_list[0]==id) return n; return NULL; }
static void view_clear_flag(struct view *v,int flag) { (void)v; (void)flag; }
static CGError SLSGetWindowBounds(int connection,uint32_t id,CGRect *frame) { (void)connection; *frame=actual[id-1]; return kCGErrorSuccess; }
static void SLSGetCurrentCursorLocation(int connection,CGPoint *point) { (void)connection; *point=CGPointZero; }
static void SLSDisableUpdate(int connection) { (void)connection; assert(update_depth==0); ++update_depth; ++disable_calls; }
static void SLSReenableUpdate(int connection) { (void)connection; assert(update_depth==1); --update_depth; }
static bool scripting_addition_set_layer(uint32_t id,int layer) { (void)id; (void)layer; return true; }
static int sa_batch_depth, sa_batch_flushes;
static void scripting_addition_batch_begin(void) { ++sa_batch_depth; }
static bool scripting_addition_batch_flush(void) { ++sa_batch_flushes; return true; }
static bool scripting_addition_batch_end(void) { assert(sa_batch_depth>0); --sa_batch_depth; return true; }
static bool scripting_addition_move_window(uint32_t id,double x,double y) { ++moves; if(move_fails) return false; actual[id-1].origin=CGPointMake(x,y); return true; }
static void window_manager_set_window_frame(struct window *w,double x,double y,double width,double height) { ++ax_calls; actual[w->id-1]=CGRectMake(x,y,width,height); }
static void window_manager_resize_window(struct window *w,double width,double height) { ++ax_calls; actual[w->id-1].size=CGSizeMake(width,height); }
static void hwm_column_width(struct view *v,struct window *w,double width) { (void)v; w->strip_width=width; }
static uint32_t hidden_tab;
static bool hwm_workflow_tab_geometry(struct view *v,struct window *w,double *y,double *height) { (void)v; (void)w; (void)y; (void)height; return false; }
static bool hwm_workflow_tab_hidden(struct window *w) { return w->id==hidden_tab; }
static void hwm_resize_submit(struct window *w,CGRect f,bool full) { if(full) window_manager_set_window_frame(w,f.origin.x,f.origin.y,f.size.width,f.size.height); else window_manager_resize_window(w,f.size.width,f.size.height); }
static bool resize_busy;
static bool hwm_resize_busy(struct window *w) { (void)w; return resize_busy; }
static void hwm_close_submit(struct window *w) { window_manager_close_window(w); }
static bool hwm_window_left_strip(struct window *w) { (void)w; return false; }
#include "../src/strip_layout.m"
static int undo_captures;
static void hwm_undo_capture(void) { ++undo_captures; }
static void hwm_hold_focus(void) {}
static void hwm_drag_started(struct window *w) { hwm_drag_window=w->id; }
#include "../src/strip_interaction.m"
#include "../src/strip_renderer.m"
#include "../src/window_transitions.m"

static void reset(void)
{
    hidden_tab=0;
    memset(windows,0,sizeof(windows)); memset(nodes,0,sizeof(nodes));
    view=(struct view){.layout=VIEW_STRIP,.window_gap=12,.root=nodes};
    clock_now=10; hwm_last_input=0; __pending_gesture=false;
    hwm_move_failures=0; hwm_resize_operations=0; ax_calls=0; moves=0; disable_calls=0; update_depth=0;
    hwm_backend_ok=true; move_fails=false;
    g_mouse_state.window=NULL; close_calls=0; hwm_edge_window=0; hwm_edge_neighbor=0; undo_captures=0;
    for(int i=0;i<4;i++) {
        windows[i].id=i+1; windows[i].application=&application;
        windows[i].frame=actual[i]=CGRectMake(100+i*80,100,400,600);
        windows[i].strip_width=400;
        alphas[i]=.85;
        nodes[i].window_count=1; nodes[i].window_list[0]=i+1;
        nodes[i].next=i<3 ? &nodes[i+1] : NULL;
    }
    hwm_layout(&view,false); hwm_render(&view,clock_now);
    clock_now+=1; hwm_render(&view,clock_now);
    ax_calls=0; moves=0; disable_calls=0; hwm_resize_operations=0;
}
static void test_pan_and_late_notifications(void)
{
    reset(); __pending_gesture=true;
    for(int step=1;step<=80;step++) {
        view.strip_offset=step*11.5;
        clock_now+=1.0/120;
        hwm_last_input=clock_now;
        hwm_render(&view,clock_now);
        for(int i=0;i<4;i++) {
            CGRect cached=windows[i].strip_last_frame;
            actual[i].origin.x+=44; // A stale app notification during live input.
            assert(horizontal_window_moved(&windows[i]));
            assert(horizontal_window_changed(&windows[i],&view,false));
            assert(CGRectEqualToRect(cached,windows[i].strip_last_frame));
            actual[i]=cached;
        }
    }
    assert(ax_calls==0 && hwm_resize_operations==0);
    assert(disable_calls==80 && update_depth==0); // One compositor batch per pan frame.
    // A settled drift correction still works and still does not resize.
    __pending_gesture=false; clock_now+=1;
    actual[0].origin.x+=44;
    assert(horizontal_window_changed(&windows[0],&view,false));
    assert(!CGRectIsNull(windows[0].strip_last_frame));
    hwm_render(&view,clock_now);
    assert(actual[0].origin.x==round(12-view.strip_offset));
    assert(ax_calls==0 && hwm_resize_operations==0);
}
static void test_retarget_during_scroll(void)
{
    reset(); view.strip_offset=200; hwm_render(&view,clock_now);
    double source=windows[0].strip_last_frame.origin.x-12+windows[0].strip_last_offset;
    view.strip_offset=250; // Input advanced since the last displayed frame.
    windows[0].strip_width=650;
    hwm_layout(&view,true);
    assert(windows[0].strip_from_x==source);
    assert(windows[0].strip_from_width==400);
    clock_now+=.12; hwm_render(&view,clock_now);
    double shown=windows[0].strip_last_frame.size.width;
    assert(shown>400 && shown<650);
    windows[0].strip_width=300;
    hwm_layout(&view,true);
    assert(windows[0].strip_from_width==shown); // Reversal starts where it was drawn.
    clock_now+=1; hwm_render(&view,clock_now);
    assert(windows[0].strip_last_frame.size.width==300);
    assert(update_depth==0);
}
static void test_new_window_and_dynamic_stack(void)
{
    reset();
    windows[3].strip_initialized=false;
    actual[3]=CGRectMake(700,250,450,400);
    windows[2].strip_column=3; windows[3].strip_column=3;
    hwm_layout(&view,true);
    assert(windows[3].strip_from_x==688 && windows[3].strip_from_y==199);
    assert(windows[3].strip_from_width==450);
    assert(windows[2].strip_world_x==windows[3].strip_world_x);
    assert(windows[3].strip_world_y>windows[2].strip_world_y);
    clock_now+=.12; hwm_render(&view,clock_now);
    assert(windows[3].strip_last_frame.size.width>400 && windows[3].strip_last_frame.size.width<450);
    clock_now+=1; hwm_render(&view,clock_now);
    assert(windows[3].strip_last_frame.size.height==444);
}
static void test_failure_releases_compositor(void)
{
    reset(); view.strip_offset=200; move_fails=true;
    assert(!hwm_render(&view,clock_now));
    assert(update_depth==0 && hwm_move_failures==1 && !hwm_backend_ok);
}
static void test_floating_reversal_and_close_refusal(void)
{
    reset(); struct window *w=&windows[0]; w->floating=true;
    CGRect target=CGRectMake(300,180,800,650);
    CGRect original=actual[0];
    hwm_float_to(w,target);
    assert(CGRectEqualToRect(w->strip_float_from,original));
    clock_now+=.12; assert(hwm_render_floating(clock_now));
    assert(actual[0].size.width>original.size.width && actual[0].size.width<target.size.width);
    CGRect mid=actual[0];
    hwm_float_to(w,original);
    assert(CGRectEqualToRect(w->strip_float_from,mid));
    clock_now+=1; assert(!hwm_render_floating(clock_now));
    assert(CGRectEqualToRect(actual[0],original));
    hwm_float_to(w,target); g_mouse_state.window=w;
    assert(!hwm_render_floating(clock_now)); // Direct manipulation takes ownership.
    assert(!w->strip_float_animating);
    g_mouse_state.window=NULL;
    hwm_close_animated(w); clock_now+=.07;
    assert(hwm_render_closing(clock_now));
    assert(alphas[0]==0 && fade_duration[0]>0 && close_calls==0); // One fade request, run by the helper.
    clock_now+=.1; assert(!hwm_render_closing(clock_now));
    assert(close_calls==1 && fabs(alphas[0]-.85)<1e-6); // Refused close remains visible.
    hwm_close_animated(w); clock_now+=.07; hwm_render_closing(clock_now);
    hwm_cancel_closing();
    assert(!w->strip_close_pending && fabs(alphas[0]-.85)<1e-6 && close_calls==1);
}
static void test_open_pop_and_close_shrink(void)
{
    reset(); struct window *w=&windows[1]; alphas[1]=1; scale_calls=0;
    hwm_pop_open(w);
    assert(w->strip_pop==1 && alphas[1]==0); // Hidden until its size has landed.
    resize_busy=true; clock_now+=.05; assert(hwm_render_pops(clock_now));
    assert(w->strip_pop==1 && alphas[1]==0 && scale_calls==0);
    resize_busy=false; clock_now+=.02; assert(hwm_render_pops(clock_now));
    assert(w->strip_pop==2 && alphas[1]==1 && fade_duration[1]>0); // The fade-in starts with the size in place.
    assert(w->strip_pop_scaled && scale_calls==1);
    clock_now+=.05; assert(hwm_render_pops(clock_now));
    assert(scale_calls==3); // Each frame resets, then applies the next scale.
    hwm_scale_reset_all(); assert(!w->strip_pop_scaled && scale_calls==4); // Before a frame moves it.
    clock_now+=.02; assert(hwm_render_pops(clock_now)); assert(w->strip_pop_scaled);
    clock_now+=1; assert(!hwm_render_pops(clock_now));
    assert(!w->strip_pop && !w->strip_pop_scaled);
    // An app that never answers is shown anyway.
    alphas[1]=1; hwm_pop_open(w); resize_busy=true; clock_now+=.4; hwm_render_pops(clock_now);
    assert(w->strip_pop==2 && alphas[1]==1); resize_busy=false;
    hwm_cancel_pops(); assert(!w->strip_pop && !w->strip_pop_scaled);
    // Closing shrinks, and a refused close is returned to full size.
    scale_calls=0; hwm_close_animated(w); clock_now+=.07; hwm_render_closing(clock_now);
    assert(w->strip_close_scaled && scale_calls==1);
    clock_now+=.1; hwm_render_closing(clock_now);
    assert(!w->strip_close_scaled && scale_calls==2);
    assert(hwm_content_width==4*400+3*12);
    // A held batch presents a whole frame at once.
    int before=disable_calls; hwm_batch_hold=true;
    view.strip_offset+=40; hwm_render(&view,clock_now); assert(update_depth==1);
    hwm_batch_release(); assert(update_depth==0 && disable_calls==before+1);
}
static void test_close_converges_both_sides(void)
{
    // Columns sit at 0, 412, 824, 1236 in a 1200-wide viewport.
    reset(); view.strip_offset=300;
    hwm_hole_note(&view,&windows[1]); assert(hwm_hole.pending);
    nodes[0].next=&nodes[2]; hwm_layout(&view,true);
    assert(view.strip_offset==300-206 && !hwm_hole.pending); // Half of 400+12: both sides move in.
    assert(windows[2].strip_world_x==412);
    // A hole left of the viewport is absorbed whole: what is on screen stays put.
    reset(); view.strip_offset=900;
    hwm_hole_note(&view,&windows[0]); nodes[0].window_count=0; view.root=&nodes[1]; hwm_layout(&view,true);
    assert(view.strip_offset==900-412);
    // One to the right of the viewport needs no camera movement at all.
    reset(); view.strip_offset=0;
    hwm_hole_note(&view,&windows[3]); nodes[2].next=NULL; hwm_layout(&view,true);
    assert(view.strip_offset==0);
    // A row leaving a stack frees no strip width.
    reset(); windows[1].strip_column=1; windows[0].strip_column=1; hwm_layout(&view,false);
    hwm_hole_note(&view,&windows[1]); assert(!hwm_hole.pending);
    view.root=nodes;
}
static void test_slow_app_and_optimistic_close(void)
{
    // While an application has not answered a size request, its notifications
    // are echoes and the settled size must not be read back as a constraint.
    reset(); windows[0].strip_width=650; hwm_layout(&view,true);
    clock_now+=.05; hwm_render(&view,clock_now);
    resize_busy=true; clock_now+=2; actual[0].size.width=520; // The app is still at an intermediate size.
    assert(hwm_render(&view,clock_now)); // Still active: waiting for the answer.
    assert(windows[0].strip_width==650 && windows[0].strip_size_pending);
    assert(horizontal_resize_event(&windows[0])); // Swallowed without asking the app.
    resize_busy=false; actual[0].size.width=650; clock_now+=.3; hwm_render(&view,clock_now);
    assert(!windows[0].strip_size_pending && windows[0].strip_width==650);
    clock_now+=1; assert(!horizontal_resize_event(&windows[0])); // Settled: handled normally.
    // A window fading out for a close gives up its place at once, and the
    // camera converges; if the app refuses, clearing the flag restores it.
    reset(); view.strip_offset=300;
    hwm_hole_note(&view,&windows[1]); windows[1].strip_close_ghost=true; hwm_layout(&view,true);
    assert(windows[2].strip_world_x==412 && view.strip_offset==300-206 && hwm_content_width==3*400+2*12);
    hwm_hole_note(&view,&windows[1]); assert(!hwm_hole.pending); // Real removal must not shift twice.
    windows[1].strip_close_ghost=false; hwm_layout(&view,true);
    assert(windows[2].strip_world_x==824 && windows[1].strip_world_x==412);
}
static void test_native_edge_resize(void)
{
    reset(); struct window *w=&windows[1];
    g_mouse_state.window=w; g_mouse_state.window_frame=actual[1];
    g_mouse_state.current_action=0;
    CGRect original=actual[1];
    horizontal_mouse_down(w,CGPointMake(CGRectGetMaxX(original),CGRectGetMidY(original)));
    assert(hwm_edge_window==w->id);
    for(int i=1;i<=30;i++) {
        actual[1].size.width=400+i*5;
        CGRect native=actual[1]; clock_now+=1.0/120;
        assert(horizontal_window_changed(w,&view,true));
        hwm_render(&view,clock_now);
        assert(CGRectEqualToRect(actual[1],native));
        assert(fabs(w->strip_width-native.size.width)<.01);
    }
    assert(undo_captures==1);
    assert(hwm_edge_finish(w,&view));
    clock_now+=1; hwm_render(&view,clock_now);
    assert(actual[1].size.width==550);
    assert(actual[2].origin.x>=CGRectGetMaxX(actual[1])+11);

    reset(); view.strip_offset=300; hwm_render(&view,clock_now);
    w=&windows[1]; original=actual[1];
    g_mouse_state.window=w; g_mouse_state.window_frame=original;
    horizontal_mouse_down(w,CGPointMake(original.origin.x,CGRectGetMidY(original)));
    actual[1].origin.x-=75; actual[1].size.width+=75;
    hwm_edge_update(w,&view); hwm_render(&view,clock_now);
    assert(view.strip_offset==375);
    assert(CGRectGetMaxX(actual[1])==CGRectGetMaxX(original));
    hwm_edge_finish(w,&view);

    reset(); windows[1].strip_column=windows[0].id;
    hwm_layout(&view,false); hwm_render(&view,clock_now);
    w=&windows[0]; g_mouse_state.window=w; g_mouse_state.window_frame=actual[0];
    horizontal_mouse_down(w,CGPointMake(CGRectGetMidX(actual[0]),CGRectGetMaxY(actual[0])));
    actual[0].size.height+=80;
    hwm_edge_update(w,&view); hwm_render(&view,clock_now);
    assert(fabs(windows[0].strip_height-(444+80))<1);
    assert(fabs(windows[1].strip_height-(444-80))<1);
    assert(undo_captures==1);
    hwm_edge_finish(w,&view);
}

static void test_tab_parking_is_move_only(void)
{
    reset(); hidden_tab=windows[1].id;
    CGSize before=actual[1].size;
    hwm_layout(&view,true); hwm_render(&view,clock_now+.1);
    assert(windows[1].strip_tab_parked);
    assert(CGSizeEqualToSize(actual[1].size,before));
    assert(actual[1].origin.y==51 && actual[1].origin.x<0);
    hidden_tab=0; hwm_layout(&view,true); hwm_render(&view,clock_now);
    assert(!windows[1].strip_tab_parked);
    assert(actual[1].origin.x>=0 && actual[1].origin.y==51);
}

static void test_spring_continuity(void)
{
    double velocity=0;
    double x=hstrip_spring(0,500,1000,.08,22,&velocity);
    double v2=0;
    assert(fabs(hstrip_spring(x,100,velocity,0,22,&v2)-x)<1e-9);
    assert(fabs(v2-velocity)<1e-9);
    assert(fabs(hstrip_spring(x,100,velocity,2,22,&v2)-100)<.001);
}

int main(void)
{
    test_tab_parking_is_move_only(); test_native_edge_resize(); test_spring_continuity();
    test_pan_and_late_notifications(); test_retarget_during_scroll();
    test_new_window_and_dynamic_stack(); test_failure_releases_compositor();
    test_floating_reversal_and_close_refusal(); test_open_pop_and_close_shrink(); test_close_converges_both_sides(); test_slow_app_and_optimistic_close();
    puts("strip runtime tests passed");
}
