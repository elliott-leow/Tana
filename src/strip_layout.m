/* Serialized strip layout; also exercised with a fake WindowServer in tests. */
static size_t hwm_items(struct view *view, CGRect bounds, HStripColumnItem **out)
{
    size_t count=0;
    for (struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) count+=n->window_count;
    HStripColumnItem *items=calloc(count ? count : 1,sizeof(*items));
    if (!items) { *out=NULL; return 0; }
    size_t i=0;
    for (struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int j=0;j<n->window_count;j++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[j]);
        if (!w) continue;
        if (!w->strip_column) w->strip_column=w->id;
        if (!(w->strip_weight>0)) w->strip_weight=1;
        if (!(w->strip_width>0)) w->strip_width=fmax(320,bounds.size.width*.58);
        uint64_t column=w->strip_full_width ? ((uint64_t)w->id<<32)|w->id : w->strip_column;
        items[i++]=(HStripColumnItem){w->id,column,w->strip_full_width ? bounds.size.width : fmax(160,w->strip_width),w->strip_weight};
    }
    *out=items; return i;
}
static void hwm_layout(struct view *view, bool animate)
{
    if (!view || view->layout!=VIEW_STRIP || !hwm_ready || hwm_paused) return;
    hwm_state_pending=true;
    CGRect bounds=hwm_bounds(view);
    HStripColumnItem *items; size_t count=hwm_items(view,bounds,&items);
    HStripColumnFrame *frames=calloc(count ? count : 1,sizeof(*frames));
    if (!items || !frames) { free(items); free(frames); return; }
    double now=hwm_now();
    double offset=hwm_offset(view,now);
    hstrip_columns_layout(items,count,view->window_gap,bounds.size.height,frames);
    for (size_t i=0;i<count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,(uint32_t)items[i].id);
        HStripColumnFrame f=frames[i];
        // Retarget from the last displayed geometry. Width commands change the
        // target before layout, so sampling that target would cause a jump.
        CGRect source=w->strip_last_frame;
        double source_offset=w->strip_last_offset;
        if(!w->strip_initialized || CGRectIsNull(source)) {
            if(SLSGetWindowBounds(g_connection,w->id,&source)!=kCGErrorSuccess) source=w->frame;
            source_offset=offset;
        }
        if(animate && !CGRectIsNull(source) && source.size.width>0 && source.size.height>0) {
            w->strip_from_x=source.origin.x-bounds.origin.x+source_offset;
            w->strip_from_y=source.origin.y-bounds.origin.y;
            w->strip_from_width=source.size.width; w->strip_from_height=source.size.height;
        } else {
            w->strip_from_x=f.x; w->strip_from_y=f.y; w->strip_from_width=f.width; w->strip_from_height=f.height;
        }
        if(!w->strip_initialized) {
            w->strip_last_frame=source; w->strip_last_offset=source_offset; w->strip_initialized=true;
            w->layer=LAYER_AUTO; scripting_addition_set_layer(w->id,LAYER_BELOW);
        }
        w->strip_world_x=f.x; w->strip_world_y=f.y; w->strip_width=f.width; w->strip_height=f.height;
        w->strip_start=animate?now:now-hwm_duration;
        if (!animate) { w->strip_from_x=f.x; w->strip_from_y=f.y; w->strip_from_width=f.width; w->strip_from_height=f.height; }
    }
    if (hwm_close_source && !view_find_window_node(view,hwm_close_source)) {
        struct window *anchor=window_manager_find_window(&g_window_manager,hwm_close_target);
        if(anchor) hwm_scroll(view,anchor->strip_world_x-hwm_close_screen_x,true);
        hwm_close_source=0; hwm_close_time=now;
    }
    free(items); free(frames); view_clear_flag(view,VIEW_IS_DIRTY); hwm_wake();
}
