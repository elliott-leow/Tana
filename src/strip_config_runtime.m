static NSDictionary *hwm_default_shortcuts(void)
{
    return @{@"left":@"alt+cmd+left",@"right":@"alt+cmd+right",@"move-left":@"shift+alt+cmd+left",@"move-right":@"shift+alt+cmd+right",
      @"move-first":@"shift+alt+cmd+,",@"move-last":@"shift+alt+cmd+.",
      @"float":@"cmd+space",@"float-alt":@"alt+cmd+space",@"full":@"shift+cmd+return",@"full-alt":@"alt+cmd+f",@"full-keypad":@"shift+cmd+keycode:76",
      @"center":@"alt+cmd+c",@"home":@"alt+cmd+0",@"close":@"cmd+q",@"terminal":@"cmd+return",@"terminal-keypad":@"cmd+keycode:76",@"browser":@"shift+cmd+w",
      @"preset-width":@"alt+cmd+r",@"fit-two":@"alt+cmd+=",@"previous":@"alt+cmd+tab",@"undo":@"alt+cmd+z",
      @"consume":@"alt+cmd+]",@"expel":@"alt+cmd+[",@"up":@"alt+cmd+up",@"down":@"alt+cmd+down",
      @"utility-mark":@"ctrl+alt+shift+space",@"utility":@"ctrl+alt+space",@"tabs":@"alt+cmd+t",@"overview":@"alt+cmd+o",
      // The Mission Control keys show Tana's overview: Mission Control itself lays every window of the
      // strip out as if it were on screen, which is no picture of the strip at all.
      @"overview-mission":@"ctrl+up",@"overview-close":@"ctrl+down",@"commands":@"ctrl+alt+p"};
}
static NSArray *hwm_width_presets(void)
{
    TanaConfigSnapshot *snapshot=[hwm_config copySnapshot];
    NSArray *widths=[[snapshot.stripWidths retain] autorelease]; [snapshot release]; return widths;
}
static void hwm_config_color(TanaConfigSnapshot *snapshot,NSString *path,double out[4],NSMutableArray *problems)
{
    NSString *text=[snapshot stringAt:path fallback:nil];
    if(text && !TanaParseColor(text,out)) [problems addObject:[NSString stringWithFormat:@"settings.%@ is not a colour such as \"#66b8ff\"",path]];
    else if(!text && [snapshot hasValueAt:path]) [problems addObject:[NSString stringWithFormat:@"settings.%@ must be a colour string",path]];
}
static double hwm_config_file_mtime(void)
{
    struct stat info;
    return stat(hwm_config.path.fileSystemRepresentation,&info)==0 ? (double)info.st_mtimespec.tv_sec+info.st_mtimespec.tv_nsec*1e-9 : 0;
}
/* Returns false, leaving every setting as it was, when the file cannot be read. */
static bool hwm_config_reload(bool announce)
{
    NSError *error=nil;
    hwm_config_mtime=hwm_config_file_mtime();
    if(![hwm_config reload:&error]) {
        warn("Tana: config retained: %s\n",error.localizedDescription.UTF8String);
        hwm_hud([NSString stringWithFormat:@"Config not loaded — previous settings kept: %@",error.localizedDescription]);
        return false;
    }
    TanaConfigSnapshot *snapshot=[hwm_config copySnapshot];
    NSMutableArray *problems=[NSMutableArray arrayWithArray:snapshot.diagnostics];
    hwm_pointer_focus=snapshot.autofocusMode==TanaAutofocusPointerMovement;
    hwm_motion_scale=[NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion?0:snapshot.motionStrength;
    hwm_duration=fmax(.001,[snapshot numberAt:@"animations.windows.duration" fallback:.36 minimum:.05 maximum:1.5]*hwm_motion_scale);
    hwm_window_zeta=1-[snapshot numberAt:@"animations.windows.bounce" fallback:0 minimum:0 maximum:.6];
    hwm_scroll_omega=[snapshot numberAt:@"animations.scroll.speed" fallback:22 minimum:8 maximum:60];
    hwm_overview_duration=fmax(.001,[snapshot numberAt:@"animations.overview.duration" fallback:.34 minimum:.05 maximum:1.5]*hwm_motion_scale);
    hwm_open_animation=[snapshot boolAt:@"animations.open" fallback:YES];
    hwm_close_shrink=[snapshot boolAt:@"animations.close" fallback:YES];
    hwm_pop_duration=fmax(.001,.22*hwm_motion_scale);
    hwm_show_map=snapshot.showStripMap;
    NSString *snap=[[snapshot stringAt:@"snap" fallback:@"center"] lowercaseString];
    hwm_snap=[snap isEqual:@"none"] ? 0 : [snap isEqual:@"column"] ? 1 : 2;
    if(![@[@"center",@"column",@"none"] containsObject:snap]) [problems addObject:@"settings.snap must be center, column or none"];
    hwm_magnet=[snapshot numberAt:@"snapMagnet" fallback:.1 minimum:0 maximum:.6];
    hwm_snap_threshold=[snapshot numberAt:@"snapThreshold" fallback:.15 minimum:.02 maximum:.6];
    hwm_swipe_gain=[snapshot numberAt:@"swipeGain" fallback:1 minimum:.4 maximum:3];
    NSString *placement=[[snapshot stringAt:@"newWindowPlacement" fallback:@"center-gap"] lowercaseString];
    hwm_new_placement=[placement isEqual:@"end"] ? 2 : [placement isEqual:@"beside-focused"] ? 1 : 0;
    if(![@[@"center-gap",@"beside-focused",@"end"] containsObject:placement]) [problems addObject:@"settings.newWindowPlacement must be center-gap, beside-focused or end"];
    NSString *follow=[[snapshot stringAt:@"focusAfterScroll" fallback:@"pointer"] lowercaseString];
    hwm_focus_follow=[follow isEqual:@"none"] ? 0 : [follow isEqual:@"center"] ? 1 : 2;
    if(![@[@"center",@"pointer",@"none"] containsObject:follow]) [problems addObject:@"settings.focusAfterScroll must be center, pointer or none"];
    hwm_hud_enabled=[snapshot boolAt:@"hud" fallback:YES];
    hwm_hot_reload=[snapshot boolAt:@"hotReload" fallback:YES];
    NSString *terminal=[snapshot stringAt:@"commands.terminal" fallback:nil],*browser=[snapshot stringAt:@"commands.browser" fallback:nil];
    [hwm_terminal_command release]; hwm_terminal_command=[terminal copy];
    [hwm_browser_command release]; hwm_browser_command=[browser copy];

    // "auto" yields to an external border tool rather than drawing a second outline.
    id border=[snapshot hasValueAt:@"border.enabled"] ? @([snapshot boolAt:@"border.enabled" fallback:YES]) : nil;
    hwm_border_mode=border ? ([border boolValue] ? 1 : 0) : 2;
    hwm_border_width=[snapshot numberAt:@"border.width" fallback:2 minimum:.5 maximum:12];
    hwm_border_radius=[snapshot numberAt:@"border.radius" fallback:12 minimum:0 maximum:40];
    double active[4]={.40,.72,1,1}, active2[4]={.71,.55,1,1}, inactive[4]={1,1,1,.14};
    hwm_config_color(snapshot,@"border.active",active,problems);
    memcpy(active2,active,sizeof(active)); if(![snapshot hasValueAt:@"border.active"]) { active2[0]=.71; active2[1]=.55; active2[2]=1; }
    hwm_config_color(snapshot,@"border.activeEnd",active2,problems);
    hwm_config_color(snapshot,@"border.inactive",inactive,problems);
    memcpy(hwm_border_active,active,sizeof(active)); memcpy(hwm_border_active_end,active2,sizeof(active2)); memcpy(hwm_border_inactive,inactive,sizeof(inactive));
    hwm_border_generation++;
    hwm_overview_dim=[snapshot numberAt:@"overview.dim" fallback:.38 minimum:0 maximum:.85];

    float dim=(float)[snapshot numberAt:@"inactiveOpacity" fallback:1 minimum:.3 maximum:1];
    if(dim!=hwm_inactive_alpha) { hwm_inactive_alpha=dim; hwm_alpha_sync(false); }

    // Gap setters reflow the strip; the layout animates to the new spacing.
    int gap=(int)[snapshot numberAt:@"gaps.inner" fallback:12 minimum:0 maximum:200];
    int top=(int)[snapshot numberAt:@"gaps.top" fallback:14 minimum:0 maximum:400],bottom=(int)[snapshot numberAt:@"gaps.bottom" fallback:12 minimum:0 maximum:400];
    int left=(int)[snapshot numberAt:@"gaps.left" fallback:12 minimum:0 maximum:400],right=(int)[snapshot numberAt:@"gaps.right" fallback:12 minimum:0 maximum:400];
    if(gap!=g_space_manager.window_gap) space_manager_set_window_gap_for_all_spaces(&g_space_manager,gap);
    if(top!=g_space_manager.top_padding) space_manager_set_top_padding_for_all_spaces(&g_space_manager,top);
    if(bottom!=g_space_manager.bottom_padding) space_manager_set_bottom_padding_for_all_spaces(&g_space_manager,bottom);
    if(left!=g_space_manager.left_padding) space_manager_set_left_padding_for_all_spaces(&g_space_manager,left);
    if(right!=g_space_manager.right_padding) space_manager_set_right_padding_for_all_spaces(&g_space_manager,right);

    for(NSString *problem in problems) warn("Tana: config: %s\n",problem.UTF8String);
    if(problems.count) hwm_hud([NSString stringWithFormat:@"Config: %@%@",problems[0],problems.count>1 ? [NSString stringWithFormat:@" (+%lu more, see config-status)",(unsigned long)problems.count-1] : @""]);
    else if(announce) hwm_hud(@"Config reloaded");
    [hwm_config_problems release]; hwm_config_problems=[problems copy];
    [snapshot release];
    hwm_wake();
    dispatch_async(dispatch_get_main_queue(),^{ hwm_menu_refresh_bindings(); });
    return true;
}
/* Saving the file is enough: no reload command is needed. */
static void hwm_config_poll(void)
{
    static double last_check;
    double now=hwm_now();
    if(!hwm_hot_reload || !hwm_config || now-last_check<.5) return;
    last_check=now;
    double modified=hwm_config_file_mtime();
    if(modified && modified!=hwm_config_mtime) hwm_config_reload(true);
}
static void hwm_config_begin(void)
{
    NSString *path=[TanaConfig defaultPath];
    hwm_config=[[TanaConfig alloc] initWithPath:path defaultShortcuts:hwm_default_shortcuts()];
    if(![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSString *directory=path.stringByDeletingLastPathComponent;
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL];
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"settings":@{@"motionStrength":@1,@"autofocus":@"pointer-movement",@"showStripMap":@YES,@"stripWidths":@[@(1.0/3),@.5,@(2.0/3),@1]},@"shortcuts":@{},@"appRules":@{}} options:NSJSONWritingPrettyPrinted error:NULL];
        int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
        if(fd>=0) { write(fd,data.bytes,data.length); close(fd); }
    }
    hwm_config_reload(false);
    dispatch_async(dispatch_get_main_queue(),^{
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            (void)n; event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup("reload-config"),HWM_NAMED_ACTION);
        }];
    });
}
static NSString *hwm_bundle(struct window *w)
{
    return [[NSRunningApplication runningApplicationWithProcessIdentifier:w->application->pid] bundleIdentifier];
}
/* Insert a new tile at the column boundary nearest the middle of the screen,
 * so it opens where the user is looking instead of at the far end. */
static bool hwm_place_center_gap(struct view *view,struct window *w,CGRect bounds)
{
    size_t capacity=0,count=0; uint64_t last=0;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) capacity+=n->window_count;
    double *lefts=calloc(capacity?capacity:1,sizeof(double)),*widths=calloc(capacity?capacity:1,sizeof(double));
    uint32_t *firsts=calloc(capacity?capacity:1,sizeof(uint32_t));
    if(lefts && widths && firsts) for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *other=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!other || other==w || !other->strip_initialized || (count && hwm_column_of(other)==last)) continue;
        last=hwm_column_of(other); lefts[count]=other->strip_world_x; widths[count]=other->strip_width; firsts[count++]=other->id;
    }
    bool placed=false;
    if(count) {
        size_t gap=hstrip_nearest_gap(view->strip_target_offset+bounds.size.width*.5,lefts,widths,count,view->window_gap);
        placed=gap<count ? hwm_place(view,w->id,firsts[gap],HSTRIP_BEFORE_COLUMN,true,NULL)
                         : hwm_place(view,w->id,firsts[count-1],HSTRIP_AFTER_COLUMN,true,NULL);
    }
    free(lefts); free(widths); free(firsts);
    return placed;
}
static void hwm_apply_app_rule_now(struct window *w)
{
    if(!w) return;
    TanaConfigSnapshot *snapshot=[hwm_config copySnapshot];
    TanaAppRule *rule=[snapshot ruleForBundleIdentifier:hwm_bundle(w)];
    struct view *view=hwm_view(); if(!view) { [snapshot release]; return; }
    CGRect bounds=hwm_bounds(view);
    bool first=!w->strip_placed;
    if(rule) {
        if(rule.width>0) w->strip_width=fmax(160,rule.widthIsFraction?rule.width*bounds.size.width:rule.width);
        window_manager_make_window_floating(&g_space_manager,&g_window_manager,w,rule.floating,true);
        if(rule.floating) {
            double width=fmin(bounds.size.width,w->strip_width>0?w->strip_width:600);
            hwm_float_to(w,CGRectMake(bounds.origin.x+(bounds.size.width-width)/2,bounds.origin.y+60,width,fmin(650,bounds.size.height-120)));
        }
    }
    bool tiled=view_find_window_node(view,w->id)!=NULL;
    if(tiled || window_check_flag(w,WINDOW_FLOAT)) w->strip_placed=true;
    if(tiled && first) {
        int mode=rule ? (rule.openBesideCurrent ? 1 : 2) : hwm_new_placement;
        if(mode==1 && w->strip_rule_anchor && w->strip_rule_anchor!=w->id) hwm_place(view,w->id,w->strip_rule_anchor,HSTRIP_AFTER_COLUMN,true,NULL);
        else if(mode==0) hwm_place_center_gap(view,w,bounds);
        hwm_layout(view,true);
        if(hwm_open_animation && hwm_duration>.01) {
            // The tile appears in its slot and grows in; neighbours slide apart around it.
            w->strip_from_x=w->strip_world_x; w->strip_from_y=w->strip_world_y;
            w->strip_from_width=w->strip_width; w->strip_from_height=w->strip_height;
            w->strip_vel_x=w->strip_vel_y=w->strip_vel_width=w->strip_vel_height=0;
            w->strip_start=hwm_now()-hwm_duration;
            hwm_pop_open(w);
        }
        hwm_preserve_focus_window=w->id; hwm_preserve_focus_until=hwm_now()+.6;
        hwm_scroll(view,hwm_center_target(view,w),true);
    } else if(rule) hwm_layout(view,true);
    [snapshot release];
}
static void hwm_apply_app_rule(struct window *w)
{
    w->strip_rule_anchor=g_window_manager.focused_window_id;
    event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)(uintptr_t)w->id,HWM_APPLY_RULE);
}
static void hwm_remember_app(const char *action)
{
    struct window *w=hwm_action_window();
    NSString *bundle=w?hwm_bundle(w):nil; if(!bundle.length) return;
    TanaConfigSnapshot *snapshot=[hwm_config copySnapshot];
    TanaAppRule *rule=[snapshot ruleForBundleIdentifier:bundle];
    double width=rule?rule.width:0;
    BOOL floating=rule?rule.floating:window_check_flag(w,WINDOW_FLOAT),beside=rule?rule.openBesideCurrent:YES;
    if(strcmp(action,"remember-width")==0) width=w->strip_width>0?w->strip_width:w->frame.size.width;
    if(strcmp(action,"remember-floating")==0) floating=!floating;
    if(strcmp(action,"remember-beside")==0) beside=!beside;
    NSError *error=nil;
    if(![hwm_config rememberRuleForBundleIdentifier:bundle width:width floating:floating openBesideCurrent:beside error:&error]) warn("Tana: cannot save app preference: %s\n",error.localizedDescription.UTF8String);
    [snapshot release];
}
static NSArray *hwm_palette_commands(void);
static bool hwm_named_action(const char *name)
{
    if(!name) return false;
    // Every command except further navigation acts on the window the cursor reached.
    if(strcmp(name,"left") && strcmp(name,"right")) hwm_nav_flush();
    if(strcmp(name,"reload-config")==0) { hwm_config_reload(true); return true; }
    if(strncmp(name,"exec:",5)==0) { hwm_spawn(@(name+5)); return true; }
    // Shutdown runs from the tick, after this command has returned.
    if(strcmp(name,"quit")==0) { hwm_stop_requested=1; hwm_wake(); return true; }
    if(strcmp(name,"commands")==0 || strcmp(name,"palette")==0) {
        dispatch_async(dispatch_get_main_queue(),^{
            [[TanaPalette shared] toggleWithCommands:hwm_palette_commands() run:^(NSString *chosen) {
                event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup(chosen.UTF8String),HWM_NAMED_ACTION);
            }];
        }); return true;
    }
    if(strcmp(name,"remember-width")==0 || strcmp(name,"remember-floating")==0 || strcmp(name,"remember-beside")==0) { hwm_remember_app(name); hwm_hud(@"App preference saved"); return true; }
    const char *names[]={"left","right","move-left","move-right","swap-left","swap-right","move-first","move-last","float","full","center","home","pause","reflow","close","terminal","browser","overview","float-alt","full-alt","terminal-keypad","full-keypad","overview-mission","overview-close"};
    int actions[]={HWM_LEFT,HWM_RIGHT,HWM_MOVE_LEFT,HWM_MOVE_RIGHT,HWM_MOVE_LEFT,HWM_MOVE_RIGHT,HWM_MOVE_FIRST,HWM_MOVE_LAST,HWM_FLOAT,HWM_FULL,HWM_CENTER,HWM_HOME,HWM_PAUSE,HWM_REFLOW,HWM_CLOSE,HWM_TERMINAL,HWM_BROWSER,HWM_OVERVIEW,HWM_FLOAT,HWM_FULL,HWM_TERMINAL,HWM_FULL,HWM_OVERVIEW,HWM_OVERVIEW_CANCEL};
    for(size_t i=0;i<sizeof(actions)/sizeof(*actions);i++) if(strcmp(name,names[i])==0) {
        if(actions[i]==HWM_FLOAT || actions[i]==HWM_FULL) hwm_undo_capture();
        hwm_action(actions[i]); return true;
    }
    if(hwm_paused || hwm_overview_active || hwm_suspended) return false;
    if(strcmp(name,"previous")==0) { hwm_preserve_focus_window=hwm_workflow_previous.id; hwm_preserve_focus_until=hwm_now()+.6; }
    bool handled=hwm_workflow_action(name);
    if(handled) { hwm_state_pending=true; hwm_wake(); }
    if(handled && strcmp(name,"preset-width")==0) {
        struct view *view=hwm_view(); struct window *w=hwm_action_window();
        if(view && w) hwm_hud([NSString stringWithFormat:@"Width %.0f%%",100*w->strip_width/hwm_bounds(view).size.width]);
    }
    if(handled && strcmp(name,"undo")==0) hwm_hud(@"Arrangement restored");
    if(handled && strcmp(name,"tabs")==0) hwm_hud(@"Stack / tabs toggled");
    return handled;
}
