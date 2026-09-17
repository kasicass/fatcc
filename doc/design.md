# fatcc / fat 设计文档

> 用 Erlang 实现一个 C 语言编译器（`fatcc`）与字节码运行时（`fat`）。
> `fatcc` 把 `.c` 编译为字节码文件 `.fc`，`fat` 加载并执行 `.fc`。
>
> 版本：v0.1（设计稿）
> 目标平台：Linux x86-64 语义（LP64、小端），实现语言：Erlang/OTP 28
> 依赖：仅 OTP 标准库（重点使用 `leex`、`yecc`、`erl_anno`、`binary`、`array`、
> `gb_trees`、`maps`、`zlib`、`erlang:crc32/1`、`file`、`io`、`string`、`unicode`、`math`、`eunit`）

---

## 0. 阅读 Erlang/OTP stdlib 后的结论

在 `/usr/local/lib/erlang28/lib` 下通读了与编译器/运行时相关的代码，得出以下可用于本项目的结论：

1. **`parsetools`（`leex` + `yecc`）是一套成熟的词法/语法分析生成器**
   - `leex` 从 `.xrl` 生成扫描器，生成模块导出 `string/1,2`、`token/2,3`、`tokens/2,3`、
     `file/1,2`。规则返回 `{token,T}`、`{end_token,T}`、`{skip_token}` 或 `{error,S}`，
     并可通过 push-back 处理需要回退的场景（awk 风格正则）。
   - `yecc` 是 LALR(1) 生成器，但 C 存在 typedef 带来的上下文相关歧义，
     经典解法是“词法器反馈（lexer hack）”，在 `yecc` 的纯函数扫描器里难以实现
     （需要 ETS/进程字典旁路）。因此本项目：
     **词法用 `leex`，语法用自研递归下降（Pratt 表达式）**，`yecc` 仅作为可选/后续方案。
2. **`erl_anno` 是 OTP 统一的位置表示**：`erl_anno:new/1`、`location/1`、`set_line/2`、
   `set_file/2`、`to_term/1`、`from_term/1`。本项目直接复用它表示 `{line,col}` 与文件，
   便于和 `erl_scan`/`erl_parse` 生态保持一致。
3. **`erl_scan`/`erl_parse` 展示了 Erlang 编译器的分层**：`tokens/3,4` 支持续扫（流式），
   `reserved_word/1` 做关键字判定。我们的扫描器/解析器沿用“token 三元组 + 位置”的方法论。
4. **内存用 `array`（O(log n)，可 grow）或页表 + `binary`**。Erlang 二进制不可变，
   整块内存不能用单个 binary 模拟；采用“分页 + 写时复制”最平衡（见 §6.2）。
5. **序列化用 `binary` 手工编解码 + `erlang:crc32/1` 校验 + `zlib:compress/1` 压缩**，
   不用 `term_to_binary/binary_to_term`，从而对不可信 `.fc` 安全（沙箱要求）。
6. **`escript` + `rebar3` 提供可执行入口**；`eunit`/`common_test` 提供测试框架；
   `math` 提供 libm 的宿主实现；`file`/`io` 提供文件与标准流。

---

## 1. 目标与非目标

### 1.1 目标

- `fatcc foo.c bar.c -o prog.fc`：把 C 源码编译、链接为单一可执行字节码镜像 `.fc`。
- `fat prog.fc [args...]`：加载并解释执行 `.fc`，把 `args` 作为 `argv` 传给 `main`。
- 纯 Erlang 实现，无 NIF、无外部 C 编译器、运行时无 `eval`。
- 对常见 C 程序（算法、字符串处理、递归、结构体、指针、文件 I/O）可编译运行。
- 可诊断：源码位置、编译错误、运行时错误与 C 调用栈。
- 安全沙箱：内存/步数有界，`.fc` 解码严格边界检查，不执行任意代码。

### 1.2 非目标（本设计不支持）

- 完整 ISO C / C++ / Objective-C。
- 与本地 `.o`/`.a` 的 ABI 级链接、内联汇编 `asm`、`_Atomic`、线程、SIMD。
- `setjmp/longjmp`、复杂 `_Complex`、`long double` 的 80/128 位精度（按 `double` 处理）。
- 非 LP64 目标、大端目标、跨平台浮点差异。
- 把 `.fc` 再编译为机器码（JIT 仅作为未来工作）。

---

## 2. 支持的 C 子集

**词法/预处理**：注释、行拼接、trigraph（默认关）、`#include`、`#define`（对象宏/函数宏/
变参 `__VA_ARGS__`/`#`/`##`）、`#undef`、`#if/#ifdef/#ifndef/#elif/#else/#endif`、
`defined`、`#error/#warning/#line/#pragma once`、预定义宏 `__FILE__ __LINE__ __DATE__ __TIME__
__STDC__ __STDC_VERSION__ __func__`。

**类型**：`void _Bool char signed/unsigned` 的 `char/short/int/long`、`float double`、
指针、数组、函数指针、`struct union enum typedef`、位域、`const/volatile/restrict`。

**表达式**：全部 C 运算符（含三目、逗号、`sizeof`、`_Alignof`、`offsetof`、强制转换、
`++/--` 前后缀、`&&/||` 短路、复合赋值、成员 `.`/`->`、下标、函数调用、字符串/复合字面量）。

**语句**：复合语句、声明、`if/else`、`while/do/for`、`switch/case/default`、
`break/continue/return/goto/label`、空语句、局部静态变量。

**数据模型（LP64）**：

| 类型 | 字节 | 对齐 | 说明 |
|---|---:|---:|---|
| `_Bool` | 1 | 1 | 取值 0/1 |
| `char` | 1 | 1 | 默认 **signed**（x86-64 Linux） |
| `short` | 2 | 2 | |
| `int` | 4 | 4 | |
| `long`/`long long` | 8 | 8 | |
| 指针/`size_t`/`ptrdiff_t` | 8 | 8 | |
| `float`/`double` | 4/8 | 4/8 | 内部均以 f64 计算 |
| 结构体/联合体 | 按成员规则 | 成员最大对齐 | 标准 padding |

整数按小端存取；标量对齐等于大小；结构体对齐取成员最大对齐并补齐到对齐倍数。

---

## 3. 总体架构

```
                    .c 文件
                       │
        ┌──────────────▼──────────────┐
        │ fatcc Driver (fatcc.erl)    │  CLI、-I/-D/-U、诊断、驱动
        └──────────────┬──────────────┘
                       │
   ┌───────────────────▼───────────────────┐
   │ 预处理 fatcc_pp                        │  翻译阶段 1–4
   │  leex(fatcc_scan) → pp-token 流         │
   │  行拼接/指令/宏展开/条件/include        │
   └───────────────────┬───────────────────┘
                       │  已展开 token 流
   ┌───────────────────▼───────────────────┐
   │ 词法 fatcc_lex                         │  关键字/常量/字符串/标点
   └───────────────────┬───────────────────┘
                       │  解析 token（带位置）
   ┌───────────────────▼───────────────────┐
   │ 语法 fatcc_parse（递归下降 + Pratt）   │  → AST (fatcc_ast.hrl)
   └───────────────────┬───────────────────┘
                       │
   ┌───────────────────▼───────────────────┐
   │ 语义 fatcc_sema + fatcc_type + layout  │  作用域/类型检查/常量折叠/
   │                                        │  struct 布局/隐式转换
   └───────────────────┬───────────────────┘
                       │  已定型 AST
   ┌───────────────────▼───────────────────┐
   │ IR fatcc_ir（线性三地址 TAC + BB）     │
   ├────────────────────────────────────────┤
   │ 优化 fatcc_opt（O0/O1/O2，可选）       │
   ├────────────────────────────────────────┤
   │ 汇编 fatcc_asm（栈式字节码 + 常量池）  │
   ├────────────────────────────────────────┤
   │ 格式 fatcc_format（.fc 编码/CRC/压缩） │
   └───────────────────┬───────────────────┘
                       │
                     prog.fc
                       │
        ┌──────────────▼──────────────┐
        │ fat_loader 解码/校验         │
        ├─────────────────────────────┤
        │ fat_vm 解释器（栈式）        │
        │  fat_mem / fat_heap 内存     │
        │  fat_libc 内建 C 标准库      │
        │  fat_sys 文件与标准流        │
        │  fat_debug 栈回溯/单步       │
        └──────────────┬──────────────┘
                       │
                    stdout / 退出码
```

**设计原则**

- 分层清晰，每层有独立可测试的数据结构与纯函数接口。
- 编译期全部用 Erlang term 表示（AST/IR/指令表），只在最后编码为紧凑二进制。
- 运行期指令在加载时解码为 Erlang tuple 列表（解释快），磁盘上保持紧凑二进制（体积小）。
- 类型信息编译期消解，运行期值只需“整数 / 浮点”两大类 + 地址。

---

## 4. 编译期设计

### 4.1 驱动 `fatcc.erl`

```
fatcc [options] file...
  -o <file>            输出 .fc（默认 a.fc / 首个输入同名）
  -I <dir>             追加头文件搜索路径
  -D<name>[=value]     预定义宏
  -U<name>             取消宏
  -E                   仅预处理，输出到 stdout
  -S                   输出可读的 .fas 汇编（调试）
  --emit-ast/--emit-ir 调试用中间结果
  -O0|-O1|-O2          优化级别（默认 -O0）
  -g                   生成调试信息（pc→源码位置）
  -std=c99|c11|c17     语言版本（默认 c11）
  --max-errors=N       错误上限
  -W<warn...>          警告开关
  -v/--version/--help
```

多文件一次调用完成“编译 + 链接”；`.fc` 是**已链接的可执行镜像**（见 §5）。
`-c` / 分离目标文件作为后续工作（§11）。

`fatcc_pp:process/2` 的输出既可以是 token 流（供后续阶段），也可以是文本（`-E`）。
诊断统一走 `fatcc_diag`，格式：

```
foo.c:12:5: error: expected ';' after expression
    return x
        ^
```

错误用 `{error, File, Loc, Msg}` 记录并汇总，退出码：0 成功，1 编译错误，2 用法错误。

### 4.2 预处理 `fatcc_pp` + `fatcc_scan`

**翻译阶段**（不完全照搬 ISO 8 阶段，但等价）：

1. 读文件（`file:read_file/1`，`unicode:characters_to_list/1`，识别 UTF-8 BOM）。
2. 行拼接：`\\\n` 删除后重扫；`\r\n` 规范化。
3. **leex 扫描**为 *preprocessing token*：identifier、pp-number、char-const、string-literal、
   punctuator、header-name（仅在 `#include` 上下文）、other、以及空白/换行（保留用于指令边界）。
   token 带 `erl_anno` 位置。
4. **指令与宏展开**：逐行（逻辑行）处理 `#` 指令；宏展开采用 Prosser 算法：
   - 每个宏展开集合带 hide set，避免递归自展开死循环；
   - 函数宏实参先“完全展开”还是“原样替换”按 `#`/`##` 规则区分；
   - `#` 字符串化、`##` 拼接（拼接结果重新扫描为 token）；
   - 变参宏 `__VA_ARGS__`、`##__VA_ARGS__` GNU 扩展。
5. 条件编译：`#if` 表达式复用词法 + 一个小型整数常量表达式求值器
   （`fatcc_pp_expr`：子集解析 + 折叠，只允许整型；`defined X` 在扫描阶段处理）。
6. `#include`：`"..."` 先当前文件目录再 `-I`；`<...>` 先 `-I` 再系统目录
   （随发行版附带 `priv/include`）；`#pragma once` + include guard 去重；
   深度上限（默认 200）与循环检测。
7. 预定义宏与 `__COUNTER__`；`#line` 修改后续位置。

**接口**

```erlang
-type tok() :: {Kind, Value, erl_anno:anno()}.
-spec process(file:filename(), pp_opts()) ->
        {ok, [tok()], pp_state()} | {error, [diag()]}.
```

宏表：`#{Name => #macro{params, variadic, body :: [tok()], predefined}}`，
作用域随 include/条件栈维护，支持 `#undef`。

### 4.3 词法 `fatcc_lex`

输入已展开的 token 流，输出“解析 token”：

```erlang
-type ptoken() ::
    {'ident', string(), anno()} | {'keyword', atom(), anno()} |
    {'int', integer(), Type, anno()} |        % Type 由后缀/进制决定
    {'float', float(), Type, anno()} |
    {'char', integer(), anno()} | {'string', [byte()], anno()} |
    {Punct :: atom(), anno()} |
    {'eof', anno()}.
```

- 关键字表（C11）与 `typedef` 名不在词法层区分，交由解析器结合符号表判断。
- 整型常量：十进制/八进制/`0x`/`0b`，后缀 `u U l L ll LL` 组合；溢出取对应类型。
- 字符/字符串转义：`\n \t \\ \' \" \0 \xHH \ooo \uXXXX \UXXXXXXXX`；
  相邻字符串字面量在语法阶段拼接。
- `sizeof` 等既是关键字又是运算符，按上下文处理。
- 位置使用 `erl_anno`，文件路径在 `erl_anno:file/1`。

### 4.4 语法分析 `fatcc_parse`

**选择递归下降 + Pratt**，理由：C 的 typedef 歧义、声明/表达式歧义（如 `(T)(x)`、
`T * x;`）在 RD 中靠“当前作用域是否 typedef”即可判定，避免 yecc 全局冲突。

**AST**（节选，`fatcc_ast.hrl`）：

```erlang
-record(translation_unit, {decls :: [decl()], anno}).
-record(decl,   {specs :: [spec()], inits :: [{declarator(), init()}], anno}).
-record(funcdef,{specs, declarator, params :: [param()],
                 body :: stmt(), stor, anno}).
-record(compound, {items :: [block_item()], anno}).
-record(if_stmt,  {cond, then, else, anno}).
-record(while_stmt,{cond, body, anno}).
-record(for_stmt,{init, cond, step, body, anno}).
-record(switch_stmt,{expr, body, anno}).
-record(return_stmt,{expr | none, anno}).
-record(expr, {kind, args, anno}).  % kind = binop|unop|call|subscript|member|
                                    %        assign|cond|cast|sizeof|ident|int|...
```

**文法要点**

- `parse_translation_unit/1` → 外部声明序列。
- `parse_declaration_specifiers` 识别存储类、类型说明符、限定符、`struct/union/enum`。
- `parse_declarator` 处理指针、数组、函数、括号优先级（用“声明器环”算法或递归组合）。
- 表达式优先级（由高到低）：
  postfix → unary → cast → `* / %` → `+ -` → `<< >>` → 关系 → 相等 → `&` → `^` → `|`
  → `&&` → `||` → `?:` → 赋值 → 逗号。
- 错误恢复：同步到 `;`、`}`、声明起始 token；报告后继续，尽量多报错。
- 记录每个声明器/表达式的位置，供语义与调试信息使用。

### 4.5 语义分析与类型系统 `fatcc_sema` / `fatcc_type` / `fatcc_layout`

**类型**

```erlang
-type ctype() ::
    void | {int, Rank, Signed} | {float, Kind} |
    {ptr, ctype()} | {array, ctype(), N | unknown} |
    {func, ctype(), [ctype()], variadic | fixed} |
    {struct, Tag, [member()], Size, Align} |
    {union,  Tag, [member()], Size, Align} |
    {enum,   Tag, BaseInt} |
    {qual, ctype(), [const|volatile|restrict]}.
```

**作用域与符号**

```erlang
-record(scope, {parent, vars = #{}, tags = #{}, typedefs = #{}, labels = #{}}).
-record(sym, {name, type, stor, linkage, offset, anno}).
```

- 名称解析：块作用域 → 函数参数 → 文件作用域 → 全局 → 内建。
- 链接属性：`static/extern/none`；同一翻译单元内合并 tentative definition。
- 检查：左值、可寻址、返回路径、类型兼容、`void*` 转换、函数原型、const 限定、
  可变参数调用、数组退化、位域约束、重复定义/缺失声明。
- **通常算术转换**：整数提升（rank < int 提升为 int）→ 取公共类型；
  有符号/无符号混合按标准规则；指针只能与同类型或 `void*` 互转（显式或兼容）。
- **隐式转换显式化**：在 AST 中插入 `cast` 节点（含宽度与符号），供 IR 直接生成。
- **常量折叠**：数组长度、枚举值、case 标签、静态初始化、位域宽度、`sizeof`、
  `_Alignof`、`offsetof` 均需整数常量表达式，在 `fatcc_sema` 内求值。
- **布局 `fatcc_layout`**：按 §2 规则计算 `size/align/offset`，处理位域、
  联合体覆盖、空结构体（GNU 扩展取 0 或 1，默认 1）。结果写入类型节点。
- 函数体检查完成后输出“已定型 AST”，所有表达式带 `type` 字段。

### 4.6 中间表示 `fatcc_ir`

选择**非 SSA 的线性三地址码（TAC）+ 基本块**，因为它天然贴近栈式字节码，易于调度。

```erlang
-record(func, {name, ret_ty, params :: [{name, ty, off}],
               n_fixed, variadic, locals :: [#local{}], frame_size,
               blocks :: [#bb{}], anno}).
-record(bb, {label, instrs :: [tac()], terminator}).
%% tac: {t, Id, Op, [Arg], ty} | {store, Ty, Addr, Val} | {call, F, Args, RetTy, Id}
%% term: {br, L} | {cbr, C, Lt, Lf} | {ret, Val | void} | {unreachable}
```

- 地址运算显式化（`&x`、数组下标、`->` 都化为 `add` + `load/store`）。
- 局部变量有确定帧偏移；取地址过的临时量也分配帧槽，其余走操作数栈。
- 控制流结构化信息（break/continue 目标、switch 跳表）在此阶段解析完成。
- 浮点与整数分别用不同 `ty`，比较/转换节点显式。

### 4.7 优化 `fatcc_opt`（可选）

在基本块与函数级别做保守优化，保证语义等价：

- O0：只做常量折叠（静态初始化必须）。
- O1：常量传播、复写传播、死代码删除、不可达块删除、跳转串接、
  窥孔（`PUSH c; ADD` → `ADD_IMM`、乘 2 的幂 → 移位）、公共子表达式（局部）。
- O2：在上面基础上增加循环不变量外提、更激进的代数化简、尾调用识别（可选）。
- 优化只作用于 TAC，不改变外部可观察行为；`-O` 会写入 `.fc` 标志。

### 4.8 字节码生成 `fatcc_asm`

由于目标是**栈式 VM**，无需寄存器分配：

1. 表达式树按后序展开为压栈/算符指令。
2. 基本块标签 → pc；`br/cbr` → `JMP/JZ/JNZ`。
3. 每个函数的局部/帧布局固定；`ENTER frame_bytes` / `RET`。
4. 常量池去重（字符串、f64、聚合初始数据）。
5. 计算并记录 `max_stack`（VM 可据此预分配/校验栈深度）。
6. 生成调试映射（当 `-g`）：`#{Pc => {File, Line, Col}}`。

汇编文本（`-S`）与二进制一一对应，便于测试。

---

## 5. `.fc` 文件格式

**目标**：紧凑、可流式校验、可扩展、对不可信输入安全。

**顶层结构**：RIFF/IFF 风格 chunk 容器。

```
偏移  字段              说明
0     magic[4]          "FATB"
4     u16 version       主版本<<8 | 次版本
6     u16 header_size   头部字节数（向前兼容）
8     u32 flags         bit0 压缩, bit1 含调试, bit2 已链接, ...
12    u32 crc32         payload 的 erlang:crc32/1
16    u32 total_size    整个文件字节数
20    u32 chunk_count
24    reserved[8]
32..  chunks

chunk := Tag[4] | Len:u32-LE | Data[Len]
Tag  ∈ "SYMT" "TYPE" "RDAT" "DATA" "BSS " "CODE" "DBG " "END "
```

- **SYMT**：符号表。每项 `{name, kind, link, type_idx, def_idx|undef}`，
  kind ∈ func/object/global/builtin。`builtin` 指向 `fat_libc` 名称。
- **TYPE**：结构/联合/枚举布局、函数签名、数组维度。
- **RDAT**：只读数据（字符串字面量、const 聚合）。
- **DATA / BSS**：已初始化/零初始化全局对象。
- **CODE**：按函数存放：`{sym_idx, ret_type_idx, n_fixed, frame_size, max_stack, code_bytes, relocs}`。
- **DBG**：调试信息。定位映射和局部变量名用 `term_to_binary(Term, [compressed])`，
  加载时用 `binary_to_term(Bin, [safe])`；核心 chunk 全手工解码。
- **END**：结束标记与再次 CRC。

**指令编码**：opcode 1 字节 + LEB128 无符号/有符号变长操作数。
例如 `LLOAD off size` → `0x28 | uleb(off) | uleb(size)`。

**链接模型（v0 简化）**：`.fc` 一次链接完成，符号全部已解析；
对未定义外部符号，若名字命中内建 libc 则标记为 `builtin`，否则编译期报
`undefined reference`。分离编译/重定位作为后续工作（§11）。

**安全**：所有长度/偏移在解码时做边界检查；拒绝未知必需 chunk；
版本不兼容时给出清晰错误；不执行、不 `binary_to_term` 核心数据。

---

## 6. 运行时 `fat` 设计

### 6.1 CLI 与启动

```
fat [options] prog.fc [program args...]
  --args a b c        显式设置 argv（否则取 prog.fc 之后的参数）
  --trace              打印每条指令
  --max-steps N        指令步数上限（默认 0 = 不限，沙箱建议设置）
  --heap-size N        堆上限（字节）
  --stack-size N       栈上限
  --dump               打印符号表/函数/常量池
  -e                   交互式单步（dev）
  -v/--version
```

启动流程：
1. `fat_loader:load/1` 读取并校验 `.fc`，解码为 `#image{}`。
2. 初始化 `#vm{}`：内存、堆、栈、文件表、环境变量、步数。
3. 在内存中构造 `argv`（每个参数一个 NUL 结尾 C 字符串数组），
   调用 `main(argc, argv, envp)`。
4. `main` 返回值 `band 16#FF` 作为进程退出码；`stdout/stderr` 刷新。

### 6.2 内存模型 `fat_mem`

线性字节地址空间，**分页 + 写时复制**（页大小 4096）：

```erlang
-record(mem, {pages   :: #{PageNo => binary()},  % 每页 4096B
              regions :: [region()],             % 合法区间
              page_size = 4096}).
-record(region, {kind, base, limit, perms}).      % rodata/data/bss/heap/stack
```

- 地址是 Erlang 非负整数；`NULL = 0`，`[0,4096)` 为不可访问的 null 保护页。
- 读未映射页：若在合法 region 内则按 0 处理（模拟 .bss/首次分配），否则 `trap: segfault`。
- 写：从 `pages` 取出该页 binary，构造新 binary 放回（只复制一页，纯函数但摊还可接受）。
- 常用标量读写提供快路径：`read8/2`、`write8/3`、`read/3`（跨页拼接）。
- 结构体赋值、数组初始化直接用 `MEMCPY`。
- 小端多字节：低地址存低位字节。读 4 字节 `[b0,b1,b2,b3]` → `b0 bor b1<<8 ...`；
  有符号用 VM 的 `sext/2`。
- 对齐由编译器保证；运行期允许非对齐（慢路径），不崩溃。

**region 布局（默认）**

```
0x0000_0000_0000_0000 - 0x0000_0000_0000_0FFF  null guard（不可访问）
0x0000_0000_0000_1000 -                          rodata
...                                              data
...                                              bss
0x0000_0001_0000_0000 - 0x0000_00FF_FFFF_FFFF  heap（向上增长）
0x0000_7FF0_0000_0000 - 0x0000_7FFF_FFFF_FFFF  stack（向下增长）
```

### 6.3 值表示

运行期值只有两类（外加 void）：

- **整数/指针**：Erlang 整数。指针就是地址（非负）。
  每个整数运算按操作码给定的位宽做**模截断**；有符号/无符号由操作码区分：
  ```
  trunc(V, W) = V band ((1 bsl W) - 1)
  from_signed(V, W) = case V >= (1 bsl (W-1)) of true -> V - (1 bsl W); false -> V end
  ```
- **浮点**：Erlang `float()`（f64）。`float`（f32）在存取时用
  `<<F:32/float>>` 往返取整，保证与 C 一致的 32 位舍入。
- **void**：无值，不入栈。

类型信息编译期已消解，VM 信任字节码；`fat_loader` 可选启用**验证器**
（§6.9）检查栈深与操作数类型，提升沙箱健壮性。

### 6.4 指令集

栈式 VM：操作数栈 + 每函数帧（帧在内存中，保证 `&local` 有效）。

```
0x00 HALT                      0x01 NOP
;; 常量
0x10 PUSH_I32 s32              0x11 PUSH_I64 s64
0x12 PUSH_F64 f64              0x13 PUSH_NULL
;; 符号地址
0x18 PUSH_GLOBAL sym           0x19 PUSH_FUNC sym
0x1A PUSH_STR stridx
;; 栈操作
0x20 POP                       0x21 DUP       0x22 DUP2     0x23 SWAP
;; 局部变量（帧相对）
0x28 LLOAD off size            0x29 LSTORE off size
0x2A LADDR off                 0x2B LZERO off size
;; 全局
0x30 GLOAD addr size           0x31 GSTORE addr size   0x32 GADDR addr
;; 内存（地址在栈顶）
0x38 LOAD size sgn             0x39 STORE size
0x3A LOAD_OFF off size sgn     0x3B STORE_OFF off size
0x3C MEMCPY                    0x3D MEMSET
;; 整数算术
0x40 ADD  0x41 SUB  0x42 MUL   0x43 DIV_S 0x44 DIV_U
0x45 MOD_S 0x46 MOD_U 0x47 NEG 0x48 SHL
0x49 SHR_U 0x4A SHR_S 0x4B AND 0x4C OR  0x4D XOR 0x4E NOT
;; 浮点算术
0x50 FADD 0x51 FSUB 0x52 FMUL  0x53 FDIV 0x54 FNEG
;; 整数比较（结果 0/1）
0x58 EQ 0x59 NE 0x5A LT_S 0x5B LE_S 0x5C GT_S 0x5D GE_S
0x5E LT_U 0x5F LE_U 0x60 GT_U 0x61 GE_U 0x62 LNOT
;; 浮点比较
0x68 FEQ 0x69 FNE 0x6A FLT 0x6B FLE 0x6C FGT 0x6D FGE
;; 转换
0x70 SEXT from to   0x71 ZEXT from to   0x72 TRUNC to
0x73 I2F from       0x74 F2I to
0x75 F32F64         0x76 F64F32
;; 控制流
0x80 JMP rel        0x81 JZ rel          0x82 JNZ rel
0x83 CALL sym argc  0x84 CALL_INDIRECT argc
0x85 RET            0x86 RET_VOID        0x87 SWITCH u32 default
;; 帧
0x90 ENTER frame_bytes  0x91 LEAVE         0x92 ALLOCA
;; 特殊
0xA0 VA_START       0xA1 VA_ARG to      0xA2 TRAP code
```

- `CALL` 会把栈顶 `argc` 个值按顺序移入新帧的前 `argc` 个参数槽；
  变参函数由 `VA_START/VA_ARG` 按 `n_fixed` 与 `nactual` 读取。
- `RET` 把栈顶作为返回值交给调用者（`RET_VOID` 无值）。
- `SWITCH` 用跳转表实现（`case` 范围/稀疏时退化为比较链）。
- `TRAP` 用于显式错误（除零、空指针、越界、`abort`）。

### 6.5 调用约定与栈帧

- 帧在内存中分配：`[参数槽][局部/溢出槽][alloca 动态区]`，8 字节对齐。
- 帧记录（VM 侧 Erlang 列表）：
  ```erlang
  -record(frame, {func, fp, ret_pc, n_fixed, nactual, locals, dyn}).
  ```
- 调用者把实参压栈；`CALL` 取 `argc` 个写入新帧参数槽，保存 `ret_pc`，
  跳转到函数入口；`RET` 恢复调用者操作数栈并把返回值压回。
- 参数槽与局部槽合并为“帧相对偏移”，`&param`/`&local` 直接由 `LADDR` 得到。
- `alloca` 在当前帧动态区向低地址（或高地址）推进，函数返回时随帧回收。
- 结构体按值传递/返回：传递时复制到调用者准备的临时区；返回时用隐藏指针（sret），
  与常见 ABI 行为一致，简化表达式语义。
- `main` 由 loader 以 `argc/argv/envp` 调用。

### 6.6 堆分配 `fat_heap`

- 地址空间来自 `heap` region，初始 `brk`，配以**首次适配 + 分开适配**的空闲链表
  （按大小分级），块头存 size/used（与 C 无关，纯实现细节）。
- `malloc/calloc/realloc/free` 在 `fat_mem` 上读写，返回地址即指针，保证对齐 16。
- `calloc` 清零；`realloc` 可原地或搬移并复制 `min(old,new)` 字节。
- 越界/重复释放 → 陷阱（`heap fault`），比真实 C 更安全。
- 堆上限来自 `--heap-size`；超过即失败（对应 `malloc` 返回 NULL）。

### 6.7 内建 C 标准库 `fat_libc`

未在 `.fc` 中定义的 `builtin` 符号在 `CALL` 时分派到 Erlang 实现：

| 模块 | 覆盖 |
|---|---|
| `fat_libc_stdio` | `printf/fprintf/sprintf/snprintf/v*`、`puts/putchar/getchar`、`fopen/fclose/fread/fwrite/fseek/ftell/fflush/fgets/fputs`、`perror`、`stdin/stdout/stderr` |
| `fat_libc_string` | `memcpy/memmove/memset/memcmp/memchr`、`strlen/strcmp/strncmp/strcpy/strncpy/strcat/strncat/strchr/strrchr/strstr/strdup` |
| `fat_libc_stdlib` | `malloc/calloc/realloc/free`、`atoi/atol/strtol/strtoul`、`abs/labs`、`rand/srand`、`qsort/bsearch`、`getenv`、`exit/abort`、`system`（默认禁用/白名单） |
| `fat_libc_ctype` | `isalpha/isdigit/isspace/...`、`tolower/toupper` |
| `fat_libc_math` | 转发到 Erlang `math`（`sqrt/pow/fabs/sin/...`），并处理 `errno` |
| `fat_sys` | 文件描述符表、标准流、`errno` 全局、时间、环境变量 |

- `printf`：自研格式解析器，支持标志 `-+ #0`、宽度/精度（含 `*`）、
  长度修饰 `hh h l ll z t j`、转换 `d i u o x X c s p f e E g G %`。
  用 `io:format` 构造输出，但 `%s/%p` 需要从内存读 C 字符串/地址。
- `FILE*` = 小整数句柄，`#fds :: #{Handle => #fd{dev, buf, pos, eof, err}}`；
  标准流映射到 Erlang `standard_io`/`standard_error`。
- `qsort`/`bsearch` 需要回调 C 比较函数：通过 `fat_vm:call_function/3` 重入解释器。
- `errno`：`fat_sys` 中的全局 int，指针 `&errno` 特判。
- 发行版携带 `priv/include/{stdio,stdlib,string,ctype,math,stddef,stdint,...}.h`，
  声明与实现一致，保证源码可编译。

### 6.8 错误、诊断与调试

- 运行期错误统一为 `{fault, Kind, Pc, Msg}`，`fat_debug` 打印 C 调用栈：
  ```
  runtime error: division by zero
      at foo.c:12:14 in compute(x=0)
      at foo.c:20:9  in main()
  ```
- 空指针解引用、越界、除零、非法指令、栈溢出、堆耗尽、`abort()` 都映射为 fault。
- `--trace` 打印 `pc, opcode, stack top, frame`；`-e` 单步（读 stdin）。
- `--max-steps`/`--heap-size`/`--stack-size` 提供确定性的沙箱边界。

### 6.9 验证器（可选但推荐）

加载时（`--verify` 默认在沙箱模式开启）对每个函数做一遍线性扫描：
检查栈深度非负且不超过 `max_stack`、跳转目标合法、`RET` 返回类型匹配、
`CALL` 目标存在、load/store 大小合法。验证失败拒绝执行，避免坏字节码拖垮 VM。

---

## 7. 模块与目录结构

```
fatcc/
├── rebar.config
├── README.md
├── doc/
│   └── design.md
├── apps/
│   ├── fatcc/                      # 编译器
│   │   ├── src/
│   │   │   ├── fatcc.erl           # CLI 驱动
│   │   │   ├── fatcc_scan.xrl      # leex 预处理 token 扫描器
│   │   │   ├── fatcc_scan.erl      #   （生成）
│   │   │   ├── fatcc_pp.erl        # 预处理指令 + 宏展开
│   │   │   ├── fatcc_pp_expr.erl   # #if 常量表达式
│   │   │   ├── fatcc_lex.erl       # token 分类
│   │   │   ├── fatcc_parse.erl     # 递归下降 + Pratt
│   │   │   ├── fatcc_ast.hrl
│   │   │   ├── fatcc_sema.erl      # 作用域/类型检查/常量折叠
│   │   │   ├── fatcc_type.erl      # 类型工具与兼容性
│   │   │   ├── fatcc_layout.erl    # struct/union/bitfield 布局
│   │   │   ├── fatcc_ir.erl        # AST → TAC
│   │   │   ├── fatcc_opt.erl       # 优化
│   │   │   ├── fatcc_asm.erl       # TAC → 栈式字节码/常量池
│   │   │   ├── fatcc_format.erl    # .fc 编码（CRC/压缩）
│   │   │   └── fatcc_diag.erl      # 诊断与错误格式化
│   │   └── test/
│   ├── fat/                        # 运行时
│   │   ├── src/
│   │   │   ├── fat.erl             # CLI
│   │   │   ├── fat_loader.erl      # .fc 解码 + 校验/验证器
│   │   │   ├── fat_format.erl      # .fc 解码（与 fatcc_format 对称）
│   │   │   ├── fat_vm.erl          # 解释器主循环
│   │   │   ├── fat_mem.erl         # 分页内存
│   │   │   ├── fat_heap.erl        # malloc/free
│   │   │   ├── fat_libc.erl        # 内建分派
│   │   │   ├── fat_libc_stdio.erl
│   │   │   ├── fat_libc_string.erl
│   │   │   ├── fat_libc_stdlib.erl
│   │   │   ├── fat_libc_ctype.erl
│   │   │   ├── fat_libc_math.erl
│   │   │   ├── fat_sys.erl         # 文件表/errno/环境
│   │   │   └── fat_debug.erl       # 栈回溯/单步/trace
│   │   ├── priv/include/*.h        # 随发行版提供的头文件
│   │   └── test/
│   └── fat_common/                 # 共享：指令编码、符号、诊断记录
│       └── src/fat_codec.erl, fat_sym.hrl
└── test/                           # 端到端 golden 测试
    ├── cases/*.c
    └── expected/*.out
```

构建：`rebar3 escriptize` 产出 `bin/fatcc`、`bin/fat`
（或 `rebar3 compile` + 两个 `escript` 包装脚本）。

---

## 8. 示例：从 C 到 `.fc` 再到运行

### 8.1 源码 `demo.c`

```c
#include <stdio.h>

long fact(long n) {
    return n < 2 ? 1 : n * fact(n - 1);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++)
        printf("fact(%s)=%ld\n", argv[i], fact(atol(argv[i])));
    return 0;
}
```

### 8.2 编译

```
$ fatcc -O1 demo.c -o demo.fc
$ fat -S demo.fc          # 或 fatcc -S demo.c
```

`fatcc_asm` 生成的 `fact` 汇编（示意）：

```
func fact (ret i64, n_fixed=1, frame=16, max_stack=3)
  ENTER 16
  LLOAD   0, 8            ; n
  PUSH_I32 2
  LT_S
  JZ     .Lelse
  PUSH_I64 1
  JMP    .Lend
.Lelse:
  LLOAD   0, 8
  LLOAD   0, 8
  PUSH_I64 1
  SUB
  CALL   fact, 1
  MUL
.Lend:
  RET
```

`.fc` 片段（HEX，示意）：

```
46 41 54 42   magic "FATB"
01 00         version 1.0
20 00         header_size = 32
01 00 00 00   flags = compressed
xx xx xx xx   crc32
...
43 4F 44 45   "CODE"
len...
28 00 10       LLOAD off=0 size=8
10 02          PUSH_I32 2
5A             LT_S
...
```

### 8.3 运行

```
$ fat demo.fc 5 6 7
fact(5)=120
fact(6)=720
fact(7)=5040
$ echo $?
0
```

---

## 9. 构建、测试与质量

- **单元测试（eunit）**：词法、宏展开、解析、类型检查、布局、编解码每一层独立测试。
- **golden 测试**：`test/cases/*.c` + `test/expected/*.out`，脚本 `fatcc` 编译、`fat` 运行、
  比对 stdout/退出码。
- **往返测试**：`.fc` 编码 → 解码 → 再编码字节一致；指令表反汇编/汇编往返。
- **差分测试（可选）**：对支持的子集，与系统 `cc` 的输出比对（仅作 CI 辅助，运行时不依赖）。
- **模糊测试**：对扫描器/预处理器/`.fc` 解码器做随机输入，确保不崩溃、不越界。
- **属性测试**：整数运算的截断/符号语义用随机向量对照 Erlang 参考实现。
- **CI**：`rebar3 eunit` + `rebar3 ct` + golden 脚本；`dialyzer` 类型检查。

---

## 10. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| M0 | 骨架、CLI、`printf` 空实现、`int main(){puts("hi");}` | 端到端跑通 |
| M1 | 整数表达式、变量、`if/while/for`、`return` | 算法小例子 |
| M2 | 函数、递归、指针、数组、取地址、内存读写 | 排序/字符串 |
| M3 | 预处理 `#include`/`#define`/条件编译 | 头文件程序 |
| M4 | `struct/union/enum/typedef`、初始化器、位域 | 结构体程序 |
| M5 | 字符串与 `stdio/string/stdlib` 常用函数 | 文件 I/O |
| M6 | `switch/goto`、函数指针、变参、`qsort` 回调 | 完整 demo |
| M7 | 浮点、`-O1`、调试信息、验证器、沙箱限额 | 性能/健壮性 |
| M8 | 分离编译/链接、`.o` 目标、文档完善 | 多 TU 工程 |

---

## 11. 非目标与后续演进

- **分离编译**：引入 `-c`/`.fo` 目标文件、重定位表 `{code_off, type, sym_idx, addend}`、
  静态库 `.fa`、链接期符号解析与合并（强弱符号、common）。
- **JIT**：把 `.fc` 翻译为 Erlang `fun`（或 Core Erlang / `beam_asm`）以换取 5–20× 提速。
- **更完整的 libc**、locale、宽字符、`setjmp/longjmp`、`_Atomic`（受限）。
- **目标可配置**：数据模型（ILP32）、端序、`char` 符号性。
- **调试器**：断点、变量查看、反向执行（利用纯函数式内存可快照）。
- **形式化**：为字节码定义小步语义，做验证器可靠性证明（未来研究）。

---

## 12. 附录

### 12.1 复用的 Erlang/OTP stdlib 模块

| 模块 | 用途 |
|---|---|
| `leex` | `.xrl` → 预处理 token 扫描器 |
| `yecc` | 备选 LALR(1) 解析（typedef 歧义处理复杂，默认不用） |
| `erl_anno` | 统一的位置/文件标注 |
| `erl_scan` / `erl_parse` | 方法论参考（token 续扫、保留字） |
| `binary` | 定点读写、字符串/浮点编解码 |
| `array` | 备选代码/常量容器 |
| `gb_trees` / `maps` | 页表、符号表、作用域、宏表 |
| `zlib` | `.fc` 压缩 |
| `erlang:crc32/1` | `.fc` 校验 |
| `file` / `filename` / `filelib` | 源文件与头文件搜索、输出 |
| `io` / `string` / `unicode` | 文本输出、字符串处理、编码 |
| `math` / `rand` | libm、`rand/srand` |
| `escript` / `rebar3` | 可执行入口与构建 |
| `eunit` / `common_test` / `dialyzer` | 测试与静态检查 |
| `proc_lib` / `logger` | 运行时日志（可选） |

### 12.2 关键设计取舍一览

| 议题 | 选择 | 理由 |
|---|---|---|
| 语法分析 | 递归下降 + Pratt | 解决 typedef/声明歧义，错误恢复好 |
| 词法 | leex | 与 stdlib 一致，正则维护方便 |
| IR | 非 SSA 线性 TAC | 贴近栈式字节码，实现简单 |
| 目标码 | 栈式字节码 | 无需寄存器分配，解释器简单可靠 |
| 内存 | 分页 + 写时复制 binary | 纯 Erlang、写放大可控、可快照 |
| 值 | 整数/指针=Erlang int，浮点=f64 | 简洁；符号性由操作码区分 |
| `.fc` | chunk 容器 + LEB128 + CRC | 紧凑、可扩展、解码安全 |
| libc | Erlang 内建 + 头文件 | 纯 Erlang，无需宿主 C |
| 链接 | v0 单次链接镜像 | 运行时简单；分离编译后置 |

### 12.3 设计一句话总结

**`fatcc` 用 leex 做词法、递归下降做语法、显式类型与 TAC 做中端、栈式字节码做后端，
把 C 编译成自描述、可校验的 `.fc`；`fat` 用分页内存模型、栈式解释器与 Erlang 内建 libc
安全地执行 `.fc`，从而在纯 Erlang/OTP 上完整实现“C 源码 → 字节码 → 运行”的闭环。**
