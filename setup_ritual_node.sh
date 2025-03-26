#!/bin/bash

# 脚本名称：setup_ritual_node.sh
# 用途：自动化设置 Ritual Infernet 节点并完成后续调用

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请以 root 用户或使用 sudo 运行此脚本${NC}"
    exit 1
fi

echo -e "${GREEN}=== 配置 Ritual 节点安装参数 ===${NC}"
read -p "请输入您的私钥（建议使用丢弃钱包，需以 0x 开头，仅限十六进制字符）： " PRIVATE_KEY
if [[ ! "$PRIVATE_KEY" =~ ^0x ]]; then
    PRIVATE_KEY="0x$PRIVATE_KEY"
fi

PRIVATE_KEY=$(echo "$PRIVATE_KEY" | tr -d '\n\r\t[:space:]' | tr -cd '0-9a-fA-Fx')
if [[ ! "$PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo -e "${RED}错误：私钥格式无效，应为 0x 开头的 64 位十六进制字符串${NC}"
    exit 1
fi

# 新增：输入 RPC URL（默认使用 https://mainnet.base.org/）
read -p "请输入 RPC URL（默认 https://mainnet.base.org/，直接回车使用默认）： " RPC_URL
RPC_URL=${RPC_URL:-"https://mainnet.base.org/"}

# Docker Compose 与 Infernet 节点版本直接使用默认值，不再提示用户
DOCKER_COMPOSE_VERSION="v2.29.2"
NODE_VERSION="1.4.0"

REPO_DIR="$HOME/infernet-container-starter"
COORDINATOR_ADDRESS="0x8D871Ef2826ac9001fB2e33fDD6379b6aaBF449c"
REGISTRY_ADDRESS="0x3B1554f346DFe5c482Bb4BA31b880c1C18412170"

echo -e "${GREEN}=== 开始设置 Ritual Infernet 节点 ===${NC}"

echo -e "${GREEN}安装构建工具和软件${NC}"
echo "检查软件包更新..."
apt update && apt upgrade -y || { echo -e "${RED}软件包更新失败${NC}"; exit 1; }

TOOLS="curl git jq lz4 build-essential screen"
for TOOL in $TOOLS; do
    if command -v $TOOL >/dev/null 2>&1; then
        echo "$TOOL 已安装，跳过..."
    else
        echo "正在安装 $TOOL..."
        apt -qy install $TOOL || { echo -e "${RED}$TOOL 安装失败${NC}"; exit 1; }
    fi
done

if command -v docker >/dev/null 2>&1 && docker run hello-world >/dev/null 2>&1; then
    echo "Docker 已安装且正常运行，跳过..."
else
    echo "正在安装 Docker..."
    apt install docker.io -y
    if ! docker run hello-world >/dev/null 2>&1; then
        echo -e "${RED}Docker 安装失败，尝试重新安装${NC}"
        apt-get remove -y docker docker-engine docker.io containerd runc
        apt-get update
        apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io
        docker run hello-world || { echo -e "${RED}Docker 重装失败${NC}"; exit 1; }
    fi
fi

if [ -x /usr/local/bin/docker-compose ] && docker-compose --version >/dev/null 2>&1; then
    echo "Docker Compose 已安装，跳过..."
else
    echo "正在安装 Docker Compose $DOCKER_COMPOSE_VERSION..."
    curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || { echo -e "${RED}Docker Compose 下载失败${NC}"; exit 1; }
    chmod +x /usr/local/bin/docker-compose
fi

DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
if [ -x $DOCKER_CONFIG/cli-plugins/docker-compose ] && docker compose version >/dev/null 2>&1; then
    echo "Docker Compose CLI 插件已安装，跳过..."
else
    echo "正在安装 Docker Compose CLI 插件..."
    mkdir -p $DOCKER_CONFIG/cli-plugins
    curl -SL https://github.com/docker/compose/releases/download/v2.20.2/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose || { echo -e "${RED}CLI 插件下载失败${NC}"; exit 1; }
    chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
fi

echo "验证 Docker Compose..."
docker compose version || { echo -e "${RED}Docker Compose 安装失败${NC}"; exit 1; }

if groups $USER | grep -q docker; then
    echo "用户已在 Docker 组，跳过..."
else
    echo "将当前用户添加到 Docker 组..."
    usermod -aG docker $USER
fi

echo -e "${GREEN}克隆 Ritual 起始仓库${NC}"
if [ -d "$REPO_DIR" ] && [ -f "$REPO_DIR/deploy/docker-compose.yaml" ]; then
    echo "仓库已存在且完整，跳过克隆..."
else
    echo "仓库不存在或不完整，正在克隆..."
    rm -rf "$REPO_DIR"
    git clone https://github.com/ritual-net/infernet-container-starter "$REPO_DIR" || { echo -e "${RED}仓库克隆失败${NC}"; exit 1; }
fi
cd "$REPO_DIR" || { echo -e "${RED}无法进入 $REPO_DIR${NC}"; exit 1; }

echo -e "${GREEN}运行 hello-world 容器${NC}"
echo "部署 hello-world 容器..."
cd "$REPO_DIR/projects/hello-world/container" || { echo -e "${RED}无法进入容器目录${NC}"; exit 1; }
docker stop hello-world 2>/dev/null || true
docker rm hello-world 2>/dev/null || true
docker run -d --name hello-world ritualnetwork/hello-world-infernet:latest 2>&1 | tee "$REPO_DIR/container.log"
echo "容器部署日志保存到 $REPO_DIR/container.log"
cat "$REPO_DIR/container.log"

echo "检查 hello-world 容器状态..."
for i in {1..3}; do
    if docker ps | grep -q "hello-world"; then
        echo -e "${GREEN}hello-world 容器正在运行${NC}"
        break
    else
        echo "第 $i 次检查：hello-world 容器未运行，等待 5 秒后重试..."
        sleep 5
        if [ $i -eq 3 ]; then
            echo -e "${RED}错误：hello-world 容器未运行，请检查 $REPO_DIR/container.log${NC}"
            cat "$REPO_DIR/container.log"
            exit 1
        fi
    fi
done

echo -e "${GREEN}配置节点${NC}"
CONFIG_FILES=(
    "$REPO_DIR/deploy/config.json"
    "$REPO_DIR/projects/hello-world/container/config.json"
)
DEPLOY_SCRIPT="$REPO_DIR/projects/hello-world/contracts/script/Deploy.s.sol"
MAKEFILE="$REPO_DIR/projects/hello-world/contracts/Makefile"
DOCKER_COMPOSE_YAML="$REPO_DIR/deploy/docker-compose.yaml"

for CONFIG_FILE in "${CONFIG_FILES[@]}"; do
    echo "正在更新 $CONFIG_FILE..."
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo "{\"coordinator_address\": \"$COORDINATOR_ADDRESS\", \"rpc_url\": \"$RPC_URL\", \"private_key\": \"$PRIVATE_KEY\", \"registry\": \"$REGISTRY_ADDRESS\", \"image\": \"ritualnetwork/hello-world-infernet:latest\", \"snapshot_sync\": {\"sleep\": 3, \"starting_sub_id\": 160000, \"batch_size\": 50, \"sync_period\": 30}, \"trail_head_blocks\": 3}" > "$CONFIG_FILE"
    [ -f "$CONFIG_FILE" ] || { echo -e "${RED}无法创建 $CONFIG_FILE${NC}"; exit 1; }
    jq . "$CONFIG_FILE" >/dev/null 2>&1 || { echo -e "${RED}$CONFIG_FILE 包含无效 JSON${NC}"; cat "$CONFIG_FILE"; exit 1; }
done

echo "正在更新 $DEPLOY_SCRIPT..."
[ -f "$DEPLOY_SCRIPT" ] || { echo -e "${RED}$DEPLOY_SCRIPT 不存在${NC}"; exit 1; }
sed -i "s/address registry = .*/address registry = $REGISTRY_ADDRESS;/" "$DEPLOY_SCRIPT"
sed -i "s/address coordinator = .*/address coordinator = $COORDINATOR_ADDRESS;/" "$DEPLOY_SCRIPT"

echo "正在更新 $MAKEFILE..."
[ -f "$MAKEFILE" ] || { echo -e "${RED}$MAKEFILE 不存在${NC}"; exit 1; }
cat <<EOF > "$MAKEFILE"
.PHONY: deploy call-contract

RPC_URL := $RPC_URL
PRIVATE_KEY := $PRIVATE_KEY

deploy:
	forge script script/Deploy.s.sol --rpc-url \$(RPC_URL) --private-key \$(PRIVATE_KEY) --broadcast -vvvv

call-contract:
	forge script script/CallContract.s.sol --rpc-url \$(RPC_URL) --private-key \$(PRIVATE_KEY) --broadcast -vvvv
EOF
chmod 644 "$MAKEFILE"
if ! grep -q "forge script" "$MAKEFILE"; then
    echo -e "${RED}更新 $MAKEFILE 失败，内容未正确写入${NC}"
    cat "$MAKEFILE"
    exit 1
fi

echo "正在更新 $DOCKER_COMPOSE_YAML..."
[ -f "$DOCKER_COMPOSE_YAML" ] || { echo -e "${RED}$DOCKER_COMPOSE_YAML 不存在${NC}"; exit 1; }
sed -i "s|image: ritualnetwork/infernet-node:.*|image: ritualnetwork/infernet-node:$NODE_VERSION|" "$DOCKER_COMPOSE_YAML"
sed -i '/restart:/d' "$DOCKER_COMPOSE_YAML"
sed -i '/on-failure/d' "$DOCKER_COMPOSE_YAML"
sed -i '/image: ritualnetwork\/infernet-node/a \ \ \ \ restart: on-failure' "$DOCKER_COMPOSE_YAML"

# 新增：将 docker-compose.yaml 中的端口映射由 4000 修改为 4888（宿主机端口），容器端口仍为 4000
sed -i 's/0\.0\.0\.0:4000:4000/0.0.0.0:4888:4000/g' "$DOCKER_COMPOSE_YAML"

echo -e "${GREEN}应用新配置${NC}"
echo "调试：显示更新后的 $DOCKER_COMPOSE_YAML 内容："
cat "$DOCKER_COMPOSE_YAML"
docker compose -f "$DOCKER_COMPOSE_YAML" config >/dev/null || { echo -e "${RED}YAML 语法错误，请检查 $DOCKER_COMPOSE_YAML${NC}"; exit 1; }
echo "停止并清理现有容器..."
docker compose -f "$DOCKER_COMPOSE_YAML" down --remove-orphans
sleep 2
echo "清理残留容器..."
docker rm -f infernet-node infernet-redis infernet-fluentbit infernet-anvil 2>/dev/null || true
echo "启动 Docker Compose 服务..."
docker compose -f "$DOCKER_COMPOSE_YAML" up -d || { echo -e "${RED}Docker Compose 启动失败${NC}"; exit 1; }

echo -e "${GREEN}安装 Foundry${NC}"
if command -v forge >/dev/null 2>&1; then
    echo "Foundry 已安装，跳过..."
else
    echo "安装 Foundry..."
    cd ~
    rm -rf foundry
    mkdir foundry && cd foundry
    curl -L https://foundry.paradigm.xyz | bash || { echo -e "${RED}Foundry 下载失败${NC}"; exit 1; }
    source ~/.bashrc
    foundryup || { echo -e "${RED}Foundry 更新失败${NC}"; exit 1; }
    command -v forge >/dev/null 2>&1 || { echo -e "${RED}Foundry 安装失败，forge 未找到${NC}"; exit 1; }
fi

cd "$REPO_DIR/projects/hello-world/contracts" || { echo -e "${RED}无法进入合约目录${NC}"; exit 1; }
echo "安装 forge-std..."
rm -rf lib/forge-std
forge install --no-commit foundry-rs/forge-std || { echo -e "${RED}forge-std 安装失败${NC}"; exit 1; }
if [ ! -f "lib/forge-std/src/Script.sol" ]; then
    echo -e "${RED}forge-std 安装失败，Script.sol 未找到${NC}"
    ls -l lib/forge-std/
    exit 1
fi
echo "forge-std 已安装"

echo "安装 infernet-sdk..."
rm -rf lib/infernet-sdk
forge install --no-commit ritual-net/infernet-sdk || { echo -e "${RED}infernet-sdk 安装失败${NC}"; exit 1; }
if [ ! -d "lib/infernet-sdk" ]; then
    echo -e "${RED}infernet-sdk 安装失败${NC}"
    ls -l lib/
    exit 1
fi
echo "infernet-sdk 已安装"

echo -e "${GREEN}部署消费者合约${NC}"
cd "$REPO_DIR/projects/hello-world/contracts" || { echo -e "${RED}无法进入合约目录${NC}"; exit 1; }
echo "部署消费者合约..."
export PRIVATE_KEY="$PRIVATE_KEY"
forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast -vvvv 2>&1 | tee "$REPO_DIR/deploy.log"
if grep -q "Deployed SaysHello:" "$REPO_DIR/deploy.log" || grep -q "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL" "$REPO_DIR/deploy.log"; then
    echo -e "${GREEN}合约部署成功，日志保存到 $REPO_DIR/deploy.log${NC}"
else
    echo -e "${RED}合约部署失败，详细信息如下：${NC}"
    cat "$REPO_DIR/deploy.log"
    echo -e "${RED}请检查 Foundry 安装、钱包余额或 RPC 配置${NC}"
    exit 1
fi

echo -e "${GREEN}=== 执行后续步骤 ===${NC}"

echo -e "${GREEN}检查节点日志${NC}"
docker logs infernet-node > "$REPO_DIR/infernet-node.log" 2>&1
if [ $? -eq 0 ]; then
    echo "节点日志已保存到 $REPO_DIR/infernet-node.log"
else
    echo -e "${RED}获取节点日志失败，请检查 Docker 服务${NC}"
fi

echo -e "${GREEN}检查容器状态${NC}"
docker ps -a > "$REPO_DIR/docker-ps.log" 2>&1
if [ $? -eq 0 ]; then
    echo "容器状态已保存到 $REPO_DIR/docker-ps.log"
else
    echo -e "${RED}获取容器状态失败，请检查 Docker 服务${NC}"
fi

echo -e "${GREEN}步骤 3：提取部署地址${NC}"
DEPLOYED_ADDRESS=$(grep "Deployed SaysHello:" "$REPO_DIR/deploy.log" | tail -1 | awk '{print $NF}')
if [ -n "$DEPLOYED_ADDRESS" ]; then
    echo "提取到的合约地址：$DEPLOYED_ADDRESS"
else
    echo -e "${RED}无法从 deploy.log 中提取合约地址${NC}"
    exit 1
fi

echo -e "${GREEN}更新 CallContract.s.sol${NC}"
CALL_CONTRACT_FILE="$REPO_DIR/projects/hello-world/contracts/script/CallContract.s.sol"
cat <<EOF > "$CALL_CONTRACT_FILE"
// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import {SaysGM} from "../src/SaysGM.sol";

contract CallContract is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        SaysGM saysGm = SaysGM($DEPLOYED_ADDRESS);

        saysGm.sayGM();

        vm.stopBroadcast();
    }
}
EOF
if grep -q "$DEPLOYED_ADDRESS" "$CALL_CONTRACT_FILE"; then
    echo "CallContract.s.sol 已更新，SaysGM 地址设置为 $DEPLOYED_ADDRESS"
else
    echo -e "${RED}更新 CallContract.s.sol 失败${NC}"
    cat "$CALL_CONTRACT_FILE"
    exit 1
fi

echo -e "${GREEN}调用合约${NC}"
cd "$REPO_DIR/projects/hello-world/contracts" || { echo -e "${RED}无法进入合约目录${NC}"; exit 1; }
forge script script/CallContract.s.sol --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast -vvvv 2>&1 | tee "$REPO_DIR/call-contract.log"
if grep -q "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL" "$REPO_DIR/call-contract.log"; then
    echo -e "${GREEN}合约调用成功，日志保存到 $REPO_DIR/call-contract.log${NC}"
else
    echo -e "${RED}合约调用失败，详细信息如下：${NC}"
    cat "$REPO_DIR/call-contract.log"
    echo -e "${RED}请检查钱包余额（需 > 0.01 ETH）、RPC 配置或节点状态${NC}"
    exit 1
fi

echo -e "${GREEN}验证 Docker${NC}"
docker run hello-world > "$REPO_DIR/docker-hello-world.log" 2>&1
if grep -q "Hello from Docker!" "$REPO_DIR/docker-hello-world.log"; then
    echo "Docker 验证成功，日志保存到 $REPO_DIR/docker-hello-world.log"
else
    echo -e "${RED}Docker 验证失败，请检查 Docker 安装${NC}"
    cat "$REPO_DIR/docker-hello-world.log"
fi

echo -e "${GREEN}=== 所有步骤执行完成 ===${NC}"
echo "节点日志：$REPO_DIR/infernet-node.log"
echo "容器状态：$REPO_DIR/docker-ps.log"
echo "部署地址：$DEPLOYED_ADDRESS（请在 Basescan 上验证：https://basescan.org/address/$DEPLOYED_ADDRESS）"
echo "调用日志：$REPO_DIR/call-contract.log"
echo "Docker 验证日志：$REPO_DIR/docker-hello-world.log"
echo -e "${GREEN}建议：请保留 15-25 USD 的 ETH 在钱包中，并检查 Basescan 确认交易${NC}"
