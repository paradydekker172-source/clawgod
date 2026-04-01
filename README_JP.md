# ClawGod

[English](README.md) | [中文](README_ZH.md) | [日本語](README_JP.md)

> [Claude Code](https://docs.anthropic.com/en/docs/claude-code) ゴッドモード。

内部機能のアンロック、制限の解除、コマンド一つでコンパイル不要。

## インストール

**macOS / Linux:**
```bash
curl -fsSL clawgod.0chen.cc/install.sh | bash
```

**Windows (PowerShell):**
```powershell
irm clawgod.0chen.cc/install.ps1 | iex
```

緑のロゴ = パッチ適用済み。オレンジのロゴ = オリジナル。

![ClawGod 適用結果](bypass.png)

## 機能一覧

### 機能アンロック

| パッチ | 内容 |
|--------|------|
| **内部ユーザーモード** | 24以上の隠しコマンド（`/share`、`/teleport`、`/issue`、`/bughunter`...）、デバッグログ、APIリクエストダンプ |
| **GrowthBook オーバーライド** | 設定ファイルで任意のフィーチャーフラグを上書き |
| **Agent Teams** | マルチエージェント協調、フラグ不要 |
| **Computer Use** | Max/Proサブスク不要で画面操作（macOS） |
| **Ultraplan** | Claude Code Remote経由のマルチエージェント計画 |
| **Ultrareview** | Claude Code Remote経由の自動バグ検出 |

### 制限の解除

| パッチ | 解除内容 |
|--------|---------|
| **CYBER_RISK_INSTRUCTION** | セキュリティテスト拒否プロンプト（ペネトレーション、C2、エクスプロイト） |
| **URL制限** | 「URLを生成・推測してはならない」指示 |
| **慎重操作** | 破壊的操作前の強制確認 |
| **ログイン通知** | 起動時の「未ログイン」リマインダー |

### ビジュアル

| パッチ | 効果 |
|--------|------|
| **グリーンテーマ** | ブランドカラー → 緑。パッチ適用を一目で確認 |
| **メッセージフィルター** | Anthropic社外ユーザーに非表示のコンテンツを表示 |

## 使い方

```bash
claude              # パッチ適用済みClaude Code
claude.orig         # オリジナル未修正版
```

## アップデート

インストールコマンドを再実行すると最新版を取得しパッチを再適用：

```bash
curl -fsSL clawgod.0chen.cc/install.sh | bash
```

## アンインストール

オリジナルの `claude` コマンドを復元：

```bash
bash <(curl -fsSL clawgod.0chen.cc/install.sh) --uninstall
```

## 要件

- Node.js >= 18 + npm
- Claude Codeアカウント（`claude auth login`）

## ライセンス

GPL-3.0 — Anthropicとは無関係です。自己責任でご使用ください。
