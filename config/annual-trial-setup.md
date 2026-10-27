# Minus 年费 3 天免费试用上线清单

试用期由 App Store 的自动续费订阅管理，不由 App 自行计时。用户下单时，Apple 会在系统付款页展示试用期、试用后年费和续订条件。

## 1. App Store Connect

1. 进入 Minus 的「订阅」，打开年费产品 `com.bieny.minus.pro.yearly`。
2. 确认该产品是 1 年周期的自动续费订阅，与月费产品位于同一订阅组。
3. 在「订阅价格」中新建「介绍性促销」：
   - 类型：免费试用
   - 时长：3 天
   - 选择需要上线的销售地区和开始日期
4. 确认年费价格、本地化名称、描述和审核截图完整，然后随 App 或内购项提交审核。

## 2. RevenueCat

1. 重新导入或同步 `com.bieny.minus.pro.yearly`。
2. 确认年费产品已加入 current Offering，并绑定到 `minus_pro` entitlement。
3. 确认 RevenueCat 已配置 Apple In-App Purchase Key，便于 StoreKit 2 交易验证。
4. Offering metadata 继续使用 `config/revenuecat-offering-metadata.json`；不要在 metadata 中对所有用户硬编码“3 天免费”。App 会从 StoreKit 读取实际试用时长，并通过 RevenueCat 判断用户是否符合资格。

## 3. 测试

1. 等待 App Store Connect 配置同步后再测试，新配置有可能需要一段时间才生效。
2. 使用从未订阅过该订阅组的全新 Sandbox Apple ID。免费试用资格按订阅组判定，一个用户通常只能使用一次介绍性促销。
3. 符合资格时，App 应显示“开始 3 天免费试用”；不符合资格时，应显示正常年费价格。
4. 点击购买后，以 Apple 系统付款页显示的试用、价格和续订条件为最终依据。
5. 验证试用开始后 `minus_pro` 立即生效，并验证恢复购买、取消续费和试用结束后的权益状态。
