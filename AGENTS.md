# AI Agent 开发指南 (AGENTS.md)

## 1. 项目概览

基于 **Cloudflare Workers** 和 **Cloudflare Containers** (Durable Objects) 的 TypeScript 项目。
利用 Cloudflare 边缘基础设施运行和管理容器化工作负载 (`AgentContainer`)。

**⚠️ 核心原则：所有文档、注释、Commit Messages 必须使用中文。**

## 2. 构建与开发命令

### 2.1 核心命令

| 命令              | 说明                          | 备注                             |
| ----------------- | ----------------------------- | -------------------------------- |
| `pnpm dev`        | 启动本地开发服务器            | 等同于 `wrangler dev`            |
| `pnpm start`      | `pnpm dev` 的别名             | -                                |
| `pnpm deploy`     | 部署到 Cloudflare             | 等同于 `wrangler deploy`         |
| `pnpm cf-typegen` | 生成 Cloudflare Bindings 类型 | 修改 `wrangler.jsonc` 后必须运行 |

### 2.2 代码质量命令

| 命令             | 说明                 | 备注                      |
| ---------------- | -------------------- | ------------------------- |
| `pnpm lint`      | 运行 oxlint 检查代码 | 高性能 Rust 实现的 linter |
| `pnpm lint:fix`  | 自动修复 lint 问题   | 等同于 `oxlint --fix`     |
| `pnpm fmt`       | 格式化代码           | 使用 oxfmt (Biome fork)   |
| `pnpm fmt:check` | 检查格式是否符合规范 | CI 中使用，不修改文件     |

### 2.3 关于测试

> **重要**: 目前仓库中**没有任何测试框架** (Jest/Vitest)。
>
> - **请勿**尝试运行 `pnpm test`（命令不存在）。
> - 验证逻辑的方式：TypeScript 编译器 (`pnpm cf-typegen`) + `pnpm lint` + 人工代码审查。
> - 如需添加测试，推荐使用 Vitest（与 Wrangler 兼容性好）。

## 3. 代码风格与规范 (Code Style)

### 3.1 格式化 (Formatting)

- **缩进**: Tab 缩进（由 oxfmt 管理）。
- **分号**: 语句末尾**不使用**分号 (ASI 风格)。
- **引号**: 字符串优先使用双引号 `"`。
- **尾随逗号**: 在多行对象/数组定义中保留尾随逗号 (ES2017+)。
- **代码块**: 始终使用花括号 `{ ... }`，即使是单行 `if` 语句。
- **行尾**: LF (`\n`)，不使用 CRLF。
- **文件末尾**: 保留一个空行。

### 3.2 命名规范 (Naming Conventions)

| 类型                       | 规范                 | 示例                                  |
| -------------------------- | -------------------- | ------------------------------------- |
| 文件名                     | `camelCase`          | `container.ts`, `sse.ts`              |
| 类 (Classes)               | `PascalCase`         | `AgentContainer`                      |
| 接口/类型 (Interface/Type) | `PascalCase`         | `SSEEvent`, `SSEEventHandler`         |
| 变量/函数                  | `camelCase`          | `verifyBasicAuth`, `processSSEStream` |
| 常量                       | `UPPER_CASE`         | `PORT`, `SINGLETON_CONTAINER_ID`      |
| 私有属性                   | `_camelCase`         | `_watchPromise`（可选前缀）           |
| 布尔变量                   | `is/has/should` 前缀 | `isAuthorized`, `hasError`            |

### 3.3 TypeScript 最佳实践

- **Strict Mode**: 严格模式已启用 (`tsconfig.json`)。**禁止**使用 `any`，除非万不得已并附加注释说明原因。
- **类型定义**:
  - 优先使用 `interface` 定义对象结构。
  - 使用 `type` 定义联合类型、函数签名。
  - 使用 `satisfies` 关键字验证导出对象：`export default { ... } satisfies ExportedHandler`。
- **环境绑定**: 只能通过 `import { env } from 'cloudflare:workers'` 访问环境变量。**禁止**使用 `process.env`。
- **空值处理**: 优先使用可选链 `?.` 和空值合并 `??`。
- **类型导入**: 使用 `import type { ... }` 显式区分纯类型导入。

### 3.4 导入顺序 (Import Order)

保持清晰的导入分层（从上到下）：

```typescript
// 1. 外部依赖 (Cloudflare 标准库、第三方包)
import { Container } from '@cloudflare/containers'
import { env } from 'cloudflare:workers'

// 2. 内部模块 (本地文件)
import { forwardRequestToContainer } from './container'
import { processSSEStream } from './sse'

// 3. 类型导入 (显式标记)
import type { SSEEvent } from './sse'
```

## 4. 架构与设计模式

### 4.1 Worker 入口与路由

- `src/index.ts` 是 Worker 的入口点。
- 它负责处理 HTTP 请求路由、基本的身份验证 (`verifyBasicAuth`) 和请求转发。
- **模式**: 函数优先返回 `null` 表示“无错误/继续处理”，返回 `Response` 对象表示“拦截/错误”。
  ```typescript
  // 示例模式
  function checkAuth(req): Response | null {
    if (fail) return new Response('401', ...);
    return null; // Pass
  }
  ```

### 4.2 AgentContainer (Durable Object)

- 位于 `src/container.ts`。
- 继承自 `Container` (来自 `@cloudflare/containers`)。
- **Singleton 模式**: 通过 `idFromName(SINGLETON_CONTAINER_ID)` 确保全局唯一实例，便于状态管理。
- **生命周期**:
  - `onStart`: 容器启动钩子。用于初始化后台任务。
  - **重要**: 后台任务 (如 `watchContainer`) 在 `onStart` 中**不应被 await**，以避免阻塞 DO 的启动过程，但必须捕获错误 (fire-and-forget 模式)。

### 4.3 错误处理 (Error Handling)

- **HTTP 错误**: 优先返回标准的 HTTP 状态码 Response (401, 403, 500)。
- **外部 I/O**: 对所有网络请求 (fetch, stream reading) 必须使用 `try-catch` 包裹。
- **SSE 流**: 处理 Server-Sent Events 时，需确保 Reader 的生命周期管理，并在连接断开时优雅退出，避免资源泄漏。

## 5. Agent 行为准则 (Behavior Guidelines)

当作为 AI Agent 修改此代码库时，请严格遵循以下规则：

1.  **语言一致性**:
    - 所有的代码注释必须使用**中文**。
    - Git Commit Message 必须使用**中文**。
    - **禁止**在代码中混用英文注释。

2.  **无损修改**:
    - 在没有测试的情况下，修改代码时必须极其谨慎。
    - 每次修改后，建议运行 `pnpm cf-typegen` 确保类型定义与 `wrangler.jsonc` 保持同步。
    - 修改现有功能前，务必理解其副作用 (Side Effects)。

3.  **配置为王**:
    - `wrangler.jsonc` 是基础设施配置的唯一真理来源 (Source of Truth)。
    - 不要硬编码配置值 (如端口、密钥)，应使用 Bindings 或环境变量。
    - 如果代码中需要新变量，必须先更新 `wrangler.jsonc` 并运行 `cf-typegen`。

4.  **文件操作**:
    - 优先修改现有文件，避免创建过多的碎片化小文件。
    - `worker-configuration.d.ts` 是自动生成的，**不要手动修改**它。
    - 保持目录结构扁平化，不要过度嵌套。

5.  **依赖管理**:
    - 仅使用 `package.json` 中定义的依赖。
    - 如需引入新库，需先评估其在 Cloudflare Workers Runtime 中的兼容性 (注意：Node.js API 支持有限)。
    - 尽量使用 Web Standard APIs (Request, Response, fetch, Streams) 而非 Node.js 特有 API。

## 6. 工具链说明

| 工具         | 说明                                    |
| ------------ | --------------------------------------- |
| **Wrangler** | 核心 CLI 工具，负责部署、开发、类型生成 |
| **oxlint**   | 高性能 Rust Linter，替代 ESLint         |
| **oxfmt**    | Biome fork 的格式化工具，替代 Prettier  |
| **pnpm**     | 包管理器 (v10.28.1)                     |

### 验证流程 (修改代码后)

```bash
# 1. 类型检查（如果修改了 wrangler.jsonc）
pnpm cf-typegen

# 2. Lint 检查
pnpm lint

# 3. 格式化检查
pnpm fmt:check

# 4. 本地开发测试
pnpm dev
```

## 7. Cursor/Copilot 规则集成

_(本项目暂未发现 `.cursorrules` 或 `.github/copilot-instructions.md` 文件。若后续添加，请在此处补充相关规则)_

---

_此文档由 AI Agent 维护，旨在统一开发标准与行为规范。_
