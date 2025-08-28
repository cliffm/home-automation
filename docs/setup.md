# Setup Guide

## Prerequisites

- Docker and Docker Compose v2.x
- Git
- (Optional) Portainer for web-based management

## Initial Setup

1. Clone this repository
2. Copy environment files
3. Configure services
4. Deploy stacks

## Environment Configuration

Each stack has an `.env.example` file. Copy these to `.env` and configure:

```bash
cd stacks/home-automation
cp .env.example .env
# Edit .env with your settings
```

## Service Configuration

Configuration files are stored in the `configs/` directory. Customize these before deployment.

## Deployment Options

### Docker Compose
```bash
cd stacks/home-automation
docker compose up -d
```

### Portainer
Configure Git integration pointing to this repository.
