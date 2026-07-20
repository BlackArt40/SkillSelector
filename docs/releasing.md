# 发布 SkillSelector

SkillSelector 发布为 GitHub Release 资产。它们是 ad-hoc 签名、启用 App Sandbox 的，且有意不使用 Developer ID 签名或公证。

1. 选择数字 `MAJOR.MINOR.PATCH` 版本并确保发布提交是干净的。
2. 运行完整验证套件：

   ```zsh
   swift test
   swift build
   ```

3. 打包并验证 Universal 2 应用：

   ```zsh
   VERSION=0.1.0
   zsh Scripts/package-dmg.sh "$VERSION"
   zsh Tests/Packaging/package-smoke.sh "$VERSION"
   ```

   这将创建 `dist/SkillSelector.app`、稳定的本地烟雾测试镜像 `dist/SkillSelector.dmg` 和版本化发布资产 `dist/SkillSelector-$VERSION.dmg`。

4. 在发布资产旁创建校验和：

   ```zsh
   shasum -a 256 "dist/SkillSelector-$VERSION.dmg" > "dist/SkillSelector-$VERSION.dmg.sha256"
   ```

5. 创建 GitHub Release 并上传版本化 DMG 和校验和：

   ```zsh
   gh release create "v$VERSION" \
     "dist/SkillSelector-$VERSION.dmg" \
     "dist/SkillSelector-$VERSION.dmg.sha256" \
     --title "SkillSelector $VERSION" \
     --generate-notes
   ```

不要将构建提交公证，也不要声称已公证。发布说明应将用户链接到 README 中的 Gatekeeper 流程。
