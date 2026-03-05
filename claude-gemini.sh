#!/bin/bash

# --- Configuration ---
OP_VAULT="Private"
OP_ITEM="GEMINI_CLAUDE_API_KEY"
PROXY_CONTAINER_NAME="claude-code-proxy"
CLAUDE_CONTAINER_NAME="claude-code-gemini"
NETWORK_NAME="claude-proxy-network"
PROXY_PORT=8080
CONTAINER_PORT=8082
IMAGE_NAME="ghcr.io/1rgs/claude-code-proxy:latest"
CLAUDE_IMAGE_NAME="node:20-slim"

echo "🔐 Fetching Gemini API Key from 1Password..."
# Read API key via 'op' binary
GEMINI_KEY=$(op read "op://$OP_VAULT/$OP_ITEM/api_key")

if [ -z "$GEMINI_KEY" ]; then
    echo "❌ Error: Could not retrieve API key from 1Password."
    exit 1
fi

# --- Docker Network Setup ---
# Create a network for containers to communicate
if ! docker network inspect $NETWORK_NAME >/dev/null 2>&1; then
    echo "🌐 Creating Docker network..."
    docker network create $NETWORK_NAME >/dev/null 2>&1
fi

# --- Docker Management ---
if [ "$(docker ps -q -f name=$PROXY_CONTAINER_NAME)" ]; then
    echo "✅ Proxy container is already running."
elif [ "$(docker ps -aq -f name=$PROXY_CONTAINER_NAME)" ]; then
    echo "🔄 Starting existing proxy container..."
    docker start $PROXY_CONTAINER_NAME
    # Ensure it's on the network
    docker network connect $NETWORK_NAME $PROXY_CONTAINER_NAME 2>/dev/null || true
else

    # Build the image locally:
    # git clone https://github.com/1rgs/claude-code-proxy.git
    # cd claude-code-proxy
    # docker build -t ghcr.io/1rgs/claude-code-proxy:latest .

    echo "🚀 Launching new proxy container..."
    # Check if image exists locally, if not try to pull it
    if ! docker image inspect $IMAGE_NAME >/dev/null 2>&1; then
        echo "📥 Pulling Docker image..."
        if ! docker pull $IMAGE_NAME; then
            echo "❌ Failed to pull image. The image may not be publicly available."
            echo "💡 You can build it locally by running:"
            echo "   git clone https://github.com/1rgs/claude-code-proxy.git"
            echo "   cd claude-code-proxy"
            echo "   docker build -t $IMAGE_NAME ."
            echo ""
            echo "   Or authenticate with GitHub Container Registry:"
            echo "   echo \$GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin"
            exit 1
        fi
    fi
    # Map local port to proxy and pass the Gemini key as an environment variable
    docker run -d \
        --name $PROXY_CONTAINER_NAME \
        --network $NETWORK_NAME \
        -p $PROXY_PORT:$CONTAINER_PORT \
        -e GEMINI_API_KEY="$GEMINI_KEY" \
        -e PREFERRED_PROVIDER="google" \
        $IMAGE_NAME
fi

# --- Claude Code Container Setup ---
# Check if Claude Code container image needs to be prepared
if ! docker image inspect claude-code-gemini:latest >/dev/null 2>&1; then
    echo "📦 Preparing Claude Code container image..."
    docker build -q -t claude-code-gemini:latest - <<'EOF'
FROM node:20-slim
RUN npm install -g @anthropic-ai/claude-code
WORKDIR /workspace
CMD ["claude"]
EOF
fi

# Get the current working directory to mount
WORKSPACE_DIR="${PWD}"

# Use container name for proxy URL (they're on the same network)
PROXY_URL="http://$PROXY_CONTAINER_NAME:$CONTAINER_PORT"

echo "🤖 Launching Claude Code in container with isolated auth..."
echo "📁 Workspace: $WORKSPACE_DIR"
echo "🔗 Proxy: $PROXY_URL"

# Run Claude Code in container with:
# - Current directory mounted
# - Proxy environment variables set
# - Connected to same network as proxy container
# - Interactive TTY for Claude Code
docker run -it --rm \
    --name $CLAUDE_CONTAINER_NAME \
    --network $NETWORK_NAME \
    -v "$WORKSPACE_DIR:/workspace" \
    -w /workspace \
    -e ANTHROPIC_BASE_URL="$PROXY_URL/v1" \
    -e ANTHROPIC_API_KEY="sk-ant-dummy-key-for-proxy" \
    -e ANTHROPIC_DEFAULT_SONNET_MODEL="google/gemini-2.5-pro" \
    claude-code-gemini:latest
