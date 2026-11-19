# Pro 商品配置与本地验证

正式商品价格由 App Store Connect 决定，App 始终显示 StoreKit 返回的本地化价格。

| 方案 | 商品 ID | 类型 | 正式价格配置 |
| --- | --- | --- | --- |
| 月付 | `com.animar.ar.companion.animo3d.monthly` | 自动续期订阅，周期 1 个月 | 美国区 USD 0.99/月 |
| 永久 | `com.animar.ar.companion.animo.lifetime` | 非消耗型内购 | 保留已有配置 |

在 App Store Connect 的当前 App 中创建订阅组 `Livo 3D Pro`，加入上述月付商品，设置周期、价格、销售地区及审核信息。取消自动续期后，用户仍可使用至已付费周期结束；到期或退款后撤销对应权益。已购买永久解锁的用户不会被要求再订阅。

`Animo3D-StoreKit` 共享 Scheme 使用本目录的 `Animo3D.storekit`，仅供本机模拟购买，不会修改 App Store Connect。普通 `Animo3D` Scheme 继续使用真实商店 / Sandbox。月付测试价格为 USD 0.99；永久的 USD 39.99 只是沿用历史本地配置的测试价格，不代表或修改正式售价。

在 Xcode 中使用：

1. 打开 `Animo3D.xcworkspace`，在左侧 `StoreKit` 分组中打开 `Animo3D.storekit`。
2. 顶部 Scheme 选择 `Animo3D-StoreKit`。
3. 运行 App，进入 Me → Pro，即可用这份配置模拟购买。

如果要在其他 Scheme 中使用，可在 Edit Scheme → Run → Options → StoreKit Configuration 中选择这份文件。无需重复创建商品配置。

本地检查：切换到 `Animo3D-StoreKit` Scheme，进入 Me → Pro，检查月付与永久价格、购买、Restore；通过 Xcode 的 StoreKit Transaction Manager 模拟续期、到期和退款。付费用户可从付费页打开系统订阅管理。

命令行回归（需要 Xcode、CocoaPods 已安装的 `xcodeproj` Ruby gem，以及可用的 iOS 模拟器）：

```bash
bash tools/run_pro_store_tests.sh <模拟器 UDID>
```

脚本在临时目录创建隔离的测试宿主，直接编译正式的 `ProStore`、权益模型及付费页，测试过程不涉及真实扣款。界面截图附件默认导出到 `/private/tmp/Animo3D-subscription-artifacts`，可用 `ANIMO_TEST_ARTIFACTS` 指定其他目录。
