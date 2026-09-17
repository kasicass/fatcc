%% Shared bytecode image / VM records for fatcc and fat.
-ifndef(FAT_IMAGE_HRL).
-define(FAT_IMAGE_HRL, true).

%% A compiled function.
-record(func, {
    name                  :: string(),
    ret_type = int        :: term(),
    params = []           :: [{string(), term(), non_neg_integer()}],
    n_fixed = 0           :: non_neg_integer(),
    variadic = false      :: boolean(),
    frame_size = 0        :: non_neg_integer(),
    code = {}             :: tuple(),
    locals = []           :: [{string(), term(), non_neg_integer()}],
    anno = none           :: term()
}).

%% A symbol in the linked image.
-record(sym, {
    name                  :: string(),
    kind = func           :: func | object | builtin,
    type = int            :: term(),
    defined = true        :: boolean()
}).

%% A global object.
-record(global, {
    name                  :: string(),
    type = int            :: term(),
    init = none           :: none | binary(),
    size = 8              :: non_neg_integer()
}).

%% The linked executable image stored in a .fc file.
-record(image, {
    entry = "main"        :: string(),
    funcs = #{}           :: #{string() => #func{}},
    symbols = #{}         :: #{string() => #sym{}},
    globals = #{}         :: #{string() => #global{}},
    strings = []          :: [binary()],
    types = #{}           :: map(),
    meta = #{}            :: map()
}).

%% Runtime VM state.
-record(vm, {
    funcs = #{}           :: map(),
    strings = #{}         :: map(),        % index -> address
    globals = #{}         :: map(),        % name -> address
    global_types = #{}    :: map(),        % name -> type
    entry = "main"        :: string(),
    mem                   :: term(),
    heap_top = 16#00100000 :: non_neg_integer(),
    heap_end = 16#0FFFFFFF :: non_neg_integer(),
    stack_top = 16#7FFF00000000 :: non_neg_integer(),
    sp                    :: non_neg_integer(),
    fp = 0                :: non_neg_integer(),
    code = {}             :: tuple(),
    pc = 1                :: pos_integer(),
    stack = []            :: list(),
    frames = []           :: list(),
    step = 0              :: non_neg_integer(),
    max_steps = infinity  :: infinity | non_neg_integer(),
    trace = false         :: boolean(),
    fds = #{}             :: map(),
    exit_code = 0         :: integer(),
    halted = false        :: boolean(),
    debug = #{}           :: map()
}).

%% A call frame.
-record(frame, {
    name                  :: string(),
    fp                    :: non_neg_integer(),
    frame_size            :: non_neg_integer(),
    ret_code = {}         :: tuple(),
    ret_pc = 1            :: pos_integer(),
    ret_fp = 0            :: non_neg_integer(),
    ret_stack = []        :: list(),
    ret_type = int        :: term(),
    n_fixed = 0           :: non_neg_integer(),
    nactual = 0           :: non_neg_integer(),
    dyn = 0               :: non_neg_integer()
}).

-endif.
