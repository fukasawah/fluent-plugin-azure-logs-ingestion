# Azure VM + Managed Identity 動作確認

`fluent-plugin-azure-logs-ingestion` を Azure VM のシステム割り当て Managed Identity で実行し、`fluent-cat` から送ったデータが Log Analytics Workspace の `FluentAliTest_CL` に入ることを確認するための最小構成です。

## 前提

- Azure CLI で対象サブスクリプションにログイン済み、かつサブスクリプション選択済み。
- 実行ユーザーはリソース作成とロール割り当てができる権限を持つこと。ユーザーアクセス管理者相当を想定します。
- SSH公開鍵が `~/.ssh/id_rsa.pub` にあること。別の鍵を使う場合はコマンド内のパスを変えてください。

## 1. Bicep を実行

可能なら `sshSourceAddressPrefix` は自分のグローバルIP `/32` にしてください。未指定でも動きますが、SSHが全IPに開きます。

```bash
cd test-azure/azure-vm

MY_IP="$(curl -s https://api.ipify.org)/32"

az deployment sub create \
  --location japaneast \
  --name fluent-ali-test \
  --template-file main.bicep \
  --parameters adminSshPublicKey="$(cat ~/.ssh/id_rsa.pub)" sshSourceAddressPrefix="$MY_IP" \
  --query properties.outputs
```

同じテンプレートは同じリソース名で再実行しても更新として扱われます。

## 2. VM セットアップとデータ送信

ローカル端末で次を実行します。スクリプトが `az deployment sub show` で DCR の endpoint と immutable ID を取得し、SSH先のVMで Ruby / Bundler / Fluentd / plugin のインストール、Fluentd起動、`fluent-cat` によるテストデータ送信まで行います。

plugin は RubyGems ではなく GitHub から取得します。既定ではローカルの `git rev-parse HEAD` のコミットを使い、そのコミットが GitHub 上にも存在する前提です。

```bash
bash setup-vm.sh
```

リソース名を変えた場合は環境変数で指定します。

```bash
RESOURCE_GROUP_NAME=rg-fluent-ali-test \
DEPLOYMENT_NAME=fluent-ali-test \
PUBLIC_IP_NAME=fluent-ali-test-pip \
ADMIN_USERNAME=azureuser \
bash setup-vm.sh
```

fork や別repositoryを使う場合は `PLUGIN_GIT_URL`、別コミットを使う場合は `PLUGIN_GIT_REF` を指定します。

```bash
PLUGIN_GIT_URL=https://github.com/<owner>/<repo>.git \
PLUGIN_GIT_REF=<commit-sha> \
bash setup-vm.sh
```

数十秒後、Azure Portal の Log Analytics Workspace で `FluentAliTest_CL` を開き、次のようなクエリで確認します。

```kusto
FluentAliTest_CL
| where source == "setup-vm.sh"
| order by TimeGenerated desc
| take 10
```

## 片付け

```bash
az group delete --name rg-fluent-ali-test
```

## 作成される主なリソース

- `rg-fluent-ali-test`
- `fluent-ali-test-vm` (`Standard_B1s`, Ubuntu 24.04 LTS, 32GB Standard SSD)
- `fluent-ali-test-dcr`
- `fluent-ali-test-vnet`, `fluent-ali-test-nsg`, `fluent-ali-test-pip`, `fluent-ali-test-nic`
- `fluentalitest-law-*`
- `FluentAliTest_CL`