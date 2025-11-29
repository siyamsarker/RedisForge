# Contributing to RedisForge

Thank you for your interest in contributing to RedisForge! This document provides guidelines and instructions for contributing to this project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [How to Contribute](#how-to-contribute)
- [Coding Standards](#coding-standards)
- [Testing Requirements](#testing-requirements)
- [Pull Request Process](#pull-request-process)
- [Project Structure](#project-structure)

## Code of Conduct

This project adheres to a Code of Conduct that all contributors are expected to follow. Please read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before contributing.

## Getting Started

RedisForge is a production-ready Redis cluster deployment system designed for:
- **DevOps Engineers**: Easy deployment, monitoring, and maintenance
- **Developers**: Clean, well-documented code for contributions
- **Production Use**: Battle-tested configurations for high-throughput systems

### Prerequisites

- Docker 20.10+ or Docker CE 24.0+
- Basic understanding of Redis clustering
- Familiarity with Bash scripting
- Experience with Envoy proxy (for proxy-related contributions)

## Development Setup

### 1. Fork and Clone

```bash
# Fork the repository on GitHub
# Then clone your fork
git clone https://github.com/YOUR_USERNAME/RedisForge.git
cd RedisForge
```

### 2. Set Up Environment

```bash
# Copy environment template
cp env.example .env

# Edit .env with your development settings
# Use simple passwords for local development
nano .env
```

### 3. Run Integration Tests

```bash
# Build and test the cluster
./tests/run-integration.sh
```

## How to Contribute

### Reporting Bugs

1. **Search existing issues** to avoid duplicates
2. **Create a new issue** with:
   - Clear, descriptive title
   - Steps to reproduce
   - Expected vs actual behavior
   - Environment details (OS, Docker version)
   - Relevant logs or screenshots

### Suggesting Enhancements

1. **Open an issue** describing:
   - The problem your enhancement solves
   - Proposed solution
   - Alternative solutions considered
   - Impact on existing functionality

### Code Contributions

1. **Pick an issue** or create one for discussion
2. **Comment on the issue** to avoid duplicate work
3. **Create a feature branch** from `main`
4. **Make your changes** following our coding standards
5. **Test thoroughly** (see Testing Requirements)
6. **Submit a pull request**

## Coding Standards

### Shell Scripts

```bash
# Use shebang and set strict mode
#!/usr/bin/env bash
set -euo pipefail

# Function documentation format
# Description of what the function does
# Arguments:
#   $1 - Description of first argument
#   $2 - Description of second argument
# Outputs:
#   What the function prints to stdout
# Returns:
#   0 on success, non-zero on failure
function_name() {
  local arg1="$1"
  local arg2="${2:-default_value}"
  
  # Clear comments for complex logic
  # ...
}
```

### Bash Style Guidelines

- Use `#!/usr/bin/env bash` (not `#!/bin/bash`)
- Always use `set -euo pipefail` for safety
- Quote all variables: `"${VAR}"` not `$VAR`
- Use `local` for function variables
- Provide default values: `"${VAR:-default}"`
- Use meaningful variable names (avoid single letters)
- Add comments for non-obvious code
- Use functions for reusable code blocks

### Docker

- Pin image versions (never use `:latest` in production)
- Document each `RUN` command
- Minimize layers where possible
- Use multi-stage builds when appropriate
- Run containers as non-root users

### Configuration Files

- Add inline comments explaining each section
- Document production vs development settings
- Explain security implications
- Provide sensible defaults
- Include valid example values

## Testing Requirements

### Before Submitting a PR

1. **Run integration tests**:
   ```bash
   ./tests/run-integration.sh
   ```

2. **Test your changes manually**:
   ```bash
   # Deploy and verify
   ./scripts/deploy.sh redis
   ./scripts/init-cluster.sh
   ./scripts/test-cluster.sh
   ```

3. **Check for shell script errors**:
   ```bash
   # Install shellcheck
   shellcheck scripts/*.sh
   ```

### Adding New Tests

- Add test cases for new features
- Update `tests/run-integration.sh` if needed
- Ensure tests are idempotent
- Document test expectations

## Pull Request Process

### 1. Prepare Your PR

- [ ] Create feature branch: `git checkout -b feature/your-feature-name`
- [ ] Make focused, logical commits
- [ ] Write clear commit messages
- [ ] Update documentation if needed
- [ ] Add/update tests
- [ ] Run all tests locally

### 2. Commit Message Format

```
<type>: <short summary>

<optional body>

<optional footer>
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `refactor`: Code refactoring
- `test`: Adding/updating tests
- `chore`: Maintenance tasks

**Examples:**
```
feat: add support for Redis Sentinel

Implements Sentinel support for automatic failover.
Adds new configuration options and deployment scripts.

Closes #123
```

```
fix: resolve cluster initialization race condition

Add retry logic to handle temporary cluster_state:fail status
during initialization.
```

### 3. Submit Pull Request

1. Push to your fork
2. Create PR against `main` branch
3. Fill out PR template completely
4. Link related issues
5. Request review

### 4. Code Review Process

- Maintainers will review within 48 hours
- Address feedback in new commits (don't force-push)
- Mark conversations as resolved when addressed
- Be patient and respectful during review

### 5. After Approval

- Maintainer will squash and merge
- Your contribution will be credited
- PR will be referenced in release notes

## Project Structure

```
RedisForge/
├── config/              # Configuration templates
│   ├── redis/          # Redis configuration
│   ├── envoy/          # Envoy proxy configuration
│   └── tls/            # TLS certificates
├── docker/             # Dockerfiles and entrypoints
│   ├── redis/          # Redis container
│   └── envoy/          # Envoy container
├── scripts/            # Deployment and utility scripts
│   ├── deploy.sh       # Main deployment script
│   ├── init-cluster.sh # Cluster initialization
│   ├── scale.sh        # Scaling operations
│   └── ...
├── tests/              # Integration tests
├── monitoring/         # Monitoring configurations
└── docs/              # Additional documentation
```

### Key Files to Understand

1. **scripts/deploy.sh** - Main deployment orchestration
2. **docker/redis/entrypoint.sh** - Redis container startup logic
3. **docker/envoy/entrypoint.sh** - Envoy configuration generation
4. **config/redis/redis.conf** - Production Redis settings
5. **config/envoy/envoy.yaml** - Envoy proxy configuration

## Areas for Contribution

### High Priority

- 🔴 Improving monitoring and alerting
- 🔴 Adding more integration tests
- 🔴 Documentation improvements
- 🔴 Performance optimization

### Medium Priority

- 🟡 Support for additional cloud providers
- 🟡 Ansible/Terraform automation
- 🟡 Enhanced backup strategies
- 🟡 Security hardening

### Good First Issues

Look for issues labeled `good-first-issue` - these are:
- Well-defined and scoped
- Have clear acceptance criteria
- Include implementation guidance
- Great for first-time contributors

## Getting Help

- **Documentation**: Check [README.md](README.md) and [docs/](docs/)
- **Issues**: Search existing issues or create new one
- **Discussions**: Use GitHub Discussions for questions
- **Email**: Contact maintainers for sensitive topics

## Recognition

Contributors are recognized in:
- Release notes
- Contributors section (coming soon)
- Git commit history

Thank you for contributing to RedisForge! 🚀
