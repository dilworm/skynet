#define LUA_LIB

#include <stdio.h>
#include <lua.h> 
#include <lauxlib.h>
#include <ldebug.h>

#include <time.h>
#include <string.h>

#if defined(__APPLE__)
#include <mach/task.h>
#include <mach/mach.h>
#endif

#define NANOSEC 1000000000
#define MICROSEC 1000000

// #define DEBUG_LOG

static int callstack_id;
static int stat_id;

static double
get_time() {
#if  !defined(__APPLE__)
	struct timespec ti;
	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ti);

	int sec = ti.tv_sec & 0xffff;
	int nsec = ti.tv_nsec;

	return (double)sec + (double)nsec / NANOSEC;	
#else
	struct task_thread_times_info aTaskInfo;
	mach_msg_type_number_t aTaskInfoCount = TASK_THREAD_TIMES_INFO_COUNT;
	if (KERN_SUCCESS != task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, (task_info_t )&aTaskInfo, &aTaskInfoCount)) {
		return 0;
	}

	int sec = aTaskInfo.user_time.seconds & 0xffff;
	int msec = aTaskInfo.user_time.microseconds;

	return (double)sec + (double)msec / MICROSEC;
#endif
}

static inline double 
diff_time(double start) {
	double now = get_time();
	if (now < start) {
		return now + 0x10000 - start;
	} else {
		return now - start;
	}
}


static int
on_enter_function(lua_State* L, lua_Debug* ar) {
    //printf("on_enter_function name=%s, top=%d\n", ar->name, lua_gettop(L));
    int funcindex = lua_gettop(L);
    lua_rawgetp(L, LUA_REGISTRYINDEX, (void*)&callstack_id);
    lua_pushthread(L);
    lua_rawget(L, -2); // get callstack table for this thread

    int newtable = 0;
    if (lua_isnil(L, -1)) { 
        lua_pop(L, 1);
        lua_pushthread(L);
        lua_newtable(L);
        newtable = 1;
    }

    lua_Integer len = luaL_len(L, -1);

    // new callstack item for this call
    lua_newtable(L); 
    lua_pushvalue(L, funcindex); 
    //printf("enterfunc=%s, %d, %p\n", ar->name, lua_type(L, funcindex), lua_topointer(L, funcindex));
    lua_setfield(L, -2, "func");
    lua_pushinteger(L, ar->linedefined);
    lua_setfield(L, -2, "linedefined");
    lua_pushstring(L, ar->short_src);
    lua_setfield(L, -2, "short_src");
    lua_pushstring(L, ar->name);
    lua_setfield(L, -2, "name");
    lua_pushnumber(L, get_time());
    lua_setfield(L, -2, "enter_time");

    // push callstack item
    lua_rawseti(L, -2, len+1);
    //printf("on_enter_function cllen=%d", (int)luaL_len(L, -1));

    if (newtable == 1) {
        lua_rawset(L, -3);
    }

    printf("on_enter_function succ, short_src=%s, name=%s, new=%d cslen=%llu\n", ar->source, ar->name, newtable, len+1);
    return 0;
}

static int 
on_leave_function(lua_State* L, lua_Debug* ar) {
    //if (strcmp("foo", ar->name) == 0)
        //luaL_error(L, "=====enter leave %s", ar->name);
    //printf("on_leave_function name=%s, top=%d %d\n", ar->name, lua_gettop(L), lua_type(L,-1));
    int funcindex = lua_gettop(L);
    lua_rawgetp(L, LUA_REGISTRYINDEX, (void*)&callstack_id);
    lua_pushthread(L);
    lua_rawget(L, -2); // get callstack table for this thread.
    if (lua_isnil(L, -1)) { 
        return 0; 
    }

    lua_Integer len = luaL_len(L, -1);
    lua_rawgeti(L, -1, len); // get callstack item for this function
    if (!lua_istable(L, -1)) { return 0; }
    lua_getfield(L, -1, "func");
    //printf("on_leave_function %s=%p\n", ar->name, lua_topointer(L, -1));
    int equal = lua_rawequal(L, -1, funcindex); // check callstack item is the one we push in on_enter_function.
    if (equal != 1) {
        return luaL_error(L, "find no enter func for '%s' leave.", ar->name);
    }

    lua_pop(L, 2);

    // pop callstack item  callstack[co][len] = nil
    lua_pushnil(L);
    lua_rawseti(L,-2,len);

    printf("on_leave_function succ %s, cslen=%llu\n", ar->name, luaL_len(L, -1));

    return 0;
}
static void 
hook_callback(lua_State* L, lua_Debug* ar) {
    lua_getinfo(L, "nfS", ar); // 'f' indicate that 'func' is pushed into the stack.

    //printf("hook_callback what=%s, name=%s, top=%d\n", ar->what, ar->name, lua_gettop(L));

    //if (strcmp(ar->what, "Lua") != 0) { // Only hook Lua functions
    //    return; 
    //}

    if (ar->event == LUA_HOOKRET) {
        on_leave_function(L, ar);
    } else {
        on_enter_function(L, ar);
    }
}

static int 
lhook(lua_State* L) {
    if (lua_gettop(L) != 0 ) {
        lua_settop(L,1);
        luaL_checktype(L, 1, LUA_TTHREAD);
    } else {
        lua_pushthread(L);
    }
    lua_pushvalue(L, 1);
    lua_rawget(L, lua_upvalueindex(4));
    if (!lua_isnil(L, -1)) { // already hooked
        luaL_error(L, "Alread hook");
        return 0;
    }
    lua_pushvalue(L, 1);
    lua_pushboolean(L, 1);
    lua_rawset(L, lua_upvalueindex(4));

    lua_sethook(L, (lua_Hook)hook_callback, LUA_MASKCALL | LUA_MASKRET, 0);
    return 0;
}

static int 
lunhook(lua_State* L) {
    if (lua_gettop(L) != 0) {
        lua_settop(L, 1);
        luaL_checktype(L, 1, LUA_TTHREAD);
    } else {
        lua_pushthread(L);
    }

    lua_pushvalue(L, 1);
    lua_rawget(L, lua_upvalueindex(4));
    if (lua_isnil(L, -1)) {
        return 0;
    }
    lua_pushvalue(L, 1);
    lua_pushnil(L);
    lua_rawset(L, lua_upvalueindex(4));
    
    lua_State* L1 = lua_tothread(L, 1);
    lua_sethook(L1, NULL, 0, 0);

    return 0;
}

static int
lstart(lua_State *L) {
	if (lua_gettop(L) != 0) {
		lua_settop(L,1);
		luaL_checktype(L, 1, LUA_TTHREAD);
	} else {
		lua_pushthread(L);
	}
	lua_pushvalue(L, 1);	// push coroutine
	lua_rawget(L, lua_upvalueindex(2));
	if (!lua_isnil(L, -1)) {
		return luaL_error(L, "Thread %p start profile more than once", lua_topointer(L, 1));
	}
	lua_pushvalue(L, 1);	// push coroutine
	lua_pushnumber(L, 0);
	lua_rawset(L, lua_upvalueindex(2));

	lua_pushvalue(L, 1);	// push coroutine
	double ti = get_time();
#ifdef DEBUG_LOG
	fprintf(stderr, "PROFILE [%p] start\n", L);
#endif
	lua_pushnumber(L, ti);
	lua_rawset(L, lua_upvalueindex(1));

	return 0;
}

static int
lstop(lua_State *L) {
	if (lua_gettop(L) != 0) {
		lua_settop(L,1);
		luaL_checktype(L, 1, LUA_TTHREAD);
	} else {
		lua_pushthread(L);
	}
	lua_pushvalue(L, 1);	// push coroutine
	lua_rawget(L, lua_upvalueindex(1));
	if (lua_type(L, -1) != LUA_TNUMBER) {
		return luaL_error(L, "Call profile.start() before profile.stop()");
	} 
	double ti = diff_time(lua_tonumber(L, -1));
	lua_pushvalue(L, 1);	// push coroutine
	lua_rawget(L, lua_upvalueindex(2));
	double total_time = lua_tonumber(L, -1);

	lua_pushvalue(L, 1);	// push coroutine
	lua_pushnil(L);
	lua_rawset(L, lua_upvalueindex(1));

	lua_pushvalue(L, 1);	// push coroutine
	lua_pushnil(L);
	lua_rawset(L, lua_upvalueindex(2));

	total_time += ti;
	lua_pushnumber(L, total_time);
#ifdef DEBUG_LOG
	fprintf(stderr, "PROFILE [%p] stop (%lf/%lf)\n", lua_tothread(L,1), ti, total_time);
#endif

	return 1;
}

static int
timing_resume(lua_State *L) {
	lua_pushvalue(L, -1);
	lua_rawget(L, lua_upvalueindex(2));
	if (lua_isnil(L, -1)) {		// check total time
		lua_pop(L,2);	// pop from coroutine
	} else {
		lua_pop(L,1);
		double ti = get_time();
#ifdef DEBUG_LOG
		fprintf(stderr, "PROFILE [%p] resume %lf\n", lua_tothread(L, -1), ti);
#endif
		lua_pushnumber(L, ti);
		lua_rawset(L, lua_upvalueindex(1));	// set start time
	}

    // check if this thread is in hook,
    // then update total yield time into last callstack item
    lua_rawgetp(L, LUA_REGISTRYINDEX, (void*)&callstack_id);
    lua_pushthread(L);
    lua_rawget(L, -2);
    if (!lua_isnil(L,-1)) {
        lua_Integer len = luaL_len(L, -1);
        if (len > 0) {
            lua_rawgeti(L, -1, len);
            lua_getfield(L, -1, "yield_time");
            if (lua_isnil(L, -1)){
                return luaL_error(L, "Can't find field 'yield_time' in last callstack item.");
            }
            double ti = diff_time(lua_tonumber(L, -1));
            lua_pop(L, 1);
            lua_getfield(L, -1, "total_yield_time");
            double tt = lua_tonumber(L, -1);
            tt += ti;
            lua_setfield(L, -2, "total_yield_time");
            lua_pop(L, 1);
        }
    }

    lua_pop(L, 2);
	lua_CFunction co_resume = lua_tocfunction(L, lua_upvalueindex(3));

	return co_resume(L);
}

static int
lresume(lua_State *L) {
	lua_pushvalue(L,1);
	
	return timing_resume(L);
}

static int
lresume_co(lua_State *L) {
	luaL_checktype(L, 2, LUA_TTHREAD);
	lua_rotate(L, 2, -1);	// 'from' coroutine rotate to the top(index -1)

	return timing_resume(L);
}

static int
timing_yield(lua_State *L) {
#ifdef DEBUG_LOG
	lua_State *from = lua_tothread(L, -1);
#endif
	lua_pushvalue(L, -1);
	lua_rawget(L, lua_upvalueindex(2));	// check total time
	if (lua_isnil(L, -1)) {
		lua_pop(L,2);
	} else {
		double ti = lua_tonumber(L, -1);
		lua_pop(L,1);

		lua_pushvalue(L, -1);	// push coroutine
		lua_rawget(L, lua_upvalueindex(1));
		double starttime = lua_tonumber(L, -1);
		lua_pop(L,1);

		double diff = diff_time(starttime);
		ti += diff;
#ifdef DEBUG_LOG
		fprintf(stderr, "PROFILE [%p] yield (%lf/%lf)\n", from, diff, ti);
#endif

		lua_pushvalue(L, -1);	// push coroutine
		lua_pushnumber(L, ti);
		lua_rawset(L, lua_upvalueindex(2));
		lua_pop(L, 1);	// pop coroutine
	}

    // check if this thread is in hook,
    // if so, record this 'yield' into last callstack item.
    lua_rawgetp(L, LUA_REGISTRYINDEX, (void*)&callstack_id);
    lua_pushthread(L);
    lua_rawget(L, -2);
    if (!lua_isnil(L,-1)) {
        lua_Integer len = luaL_len(L, -1);
        if (len > 0) {
            lua_rawgeti(L, -1, len);
            lua_pushnumber(L, get_time());
            lua_setfield(L, -1, "yield_time");
            lua_pushnumber(L, 0.0);
            lua_setfield(L, -1, "total_yield_time");
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 2);

	lua_CFunction co_yield = lua_tocfunction(L, lua_upvalueindex(3));

	return co_yield(L);
}

static int
lyield(lua_State *L) {
	lua_pushthread(L);

	return timing_yield(L);
}

static int
lyield_co(lua_State *L) {
	luaL_checktype(L, 1, LUA_TTHREAD);
	lua_rotate(L, 1, -1);
	
	return timing_yield(L);
}

LUAMOD_API int
luaopen_profile_ex(lua_State *L) {
	luaL_checkversion(L);
	luaL_Reg l[] = {
		{ "start", lstart },
		{ "stop", lstop },
		{ "resume", lresume },
		{ "yield", lyield },
		{ "resume_co", lresume_co },
		{ "yield_co", lyield_co },
		{ "hook", lhook},
		{ "unhook", lunhook},
		{ NULL, NULL },
	};
	luaL_newlibtable(L,l);
	lua_newtable(L);	// table thread->start time
	lua_newtable(L);	// table thread->total time
    lua_newtable(L);    // threads -> {threadN = is_hooked, ...}

	lua_newtable(L);	// weak table
	lua_pushliteral(L, "kv");
	lua_setfield(L, -2, "__mode");

	lua_pushvalue(L, -1);
	lua_pushvalue(L, -1);
	lua_setmetatable(L, -4); 
	lua_setmetatable(L, -4);

	lua_pushnil(L);	// cfunction (coroutine.resume or coroutine.yield)

    // ------------------------------------------------------------------------
    lua_newtable(L);    // functions -> {functionN = {time, count, file, name}, ...}
	lua_newtable(L);	// weak table
	lua_pushliteral(L, "kv");
	lua_setfield(L, -2, "__mode");
	lua_setmetatable(L, -2);

    lua_rawsetp(L, LUA_REGISTRYINDEX, (void*)&stat_id);

    lua_newtable(L);    // threads -> {threadN = callstackN,...}
	lua_newtable(L);	// weak table
	lua_pushliteral(L, "kv");
	lua_setfield(L, -2, "__mode");
	lua_setmetatable(L, -2);

    lua_rawsetp(L, LUA_REGISTRYINDEX, (void*)&callstack_id);
    // ------------------------------------------------------------------------

	//luaL_setfuncs(L,l,3);
	luaL_setfuncs(L,l,4);

	int libtable = lua_gettop(L);

	lua_getglobal(L, "coroutine");
	lua_getfield(L, -1, "resume");

	lua_CFunction co_resume = lua_tocfunction(L, -1);
	if (co_resume == NULL)
		return luaL_error(L, "Can't get coroutine.resume");
	lua_pop(L,1);

	lua_getfield(L, libtable, "resume");
	lua_pushcfunction(L, co_resume);
	lua_setupvalue(L, -2, 3);
	lua_pop(L,1);

	lua_getfield(L, libtable, "resume_co");
	lua_pushcfunction(L, co_resume);
	lua_setupvalue(L, -2, 3);
	lua_pop(L,1);

	lua_getfield(L, -1, "yield");

	lua_CFunction co_yield = lua_tocfunction(L, -1);
	if (co_yield == NULL)
		return luaL_error(L, "Can't get coroutine.yield");
	lua_pop(L,1);

	lua_getfield(L, libtable, "yield");
	lua_pushcfunction(L, co_yield);
	lua_setupvalue(L, -2, 3);
	lua_pop(L,1);

	lua_getfield(L, libtable, "yield_co");
	lua_pushcfunction(L, co_yield);
	lua_setupvalue(L, -2, 3);
	lua_pop(L,1);

	lua_settop(L, libtable);

	return 1;
}
