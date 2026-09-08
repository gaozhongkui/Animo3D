# 资源管线

App 运行时加载的一切都来自一个地方:**Supabase 桶里的 `index.json`**。除此之外没有第二份配置文件,
也没有任何需要手工登记的清单。这个目录里的脚本负责:把一个源模型或源舞蹈,变成 App 能加载的东西,
然后重新生成那份 index。

```
源模型 (.vrm/.glb)        glb_to_fbx.py ──▶ 裸网格 FBX ──▶ [ mixamo.com ] ──▶ 绑定后 FBX
                                                                                  │
                                                          fbx_to_character.py ────┤
                                                                                  ▼
源舞蹈 (Mixamo .fbx)      ── (见「新增舞蹈」) ──▶ mocap JSON     assets_src/characters/*.scn
                                                      │                           │
                                                      │              compress_textures.swift
                                                      │              render_thumbs.swift
                                                      ▼                           ▼
                                                make_catalog.py ──▶ dist/index.json
                                                                    dist/upload/
```

所有信息都从磁盘上真实存在的文件推导。没有白名单,也没有显示名对照表 —— **文件名就是名字**,
`The_Boss.scn` 在 App 里显示为 "The Boss"。想改显示名就改文件名。

---

## 新增角色

### 第 1 步 · 源模型 → 裸网格 FBX

```bash
python3 tools/glb_to_fbx.py path/to/model.vrm -o out/     # .vrm / .glb / .gltf 都支持
python3 tools/glb_to_fbx.py tools/glb/*.glb -o out/       # 批量
```

产出**没有骨架也没有蒙皮,这是故意的**:Mixamo 的自动绑定一旦发现 FBX 里已经有骨架就会**跳过绑定**
直接把模型退回来,白跑一趟。蒙皮是第 2 步从 Mixamo 那边回来的。

这一步解决了三个容易漏掉的坑:

- **材质重建为 Principled BSDF。** VRM/MToon 材质导入后是 `Emission + Transparent + Mix Shader`
  拼的,节点树里**根本没有 Principled 节点**;而 FBX 导出器是从 Principled 往回找基色贴图的,
  所以它一张都导不出去,传到 Mixamo 就是个灰模。实测一个 VRoid GLB:修之前内嵌 0 张,修之后 15 张。
- **剔除无材质的辅助网格。** 每个 VRoid 导出都带一个 `Icosphere`(42 顶点、无材质、以原点为中心
  半径 1)。它会主导包围盒,导致按它算落地时**把角色整体抬高了 1 米**,Mixamo 会对着空气绑骨架。
- **缩放烘进网格 + 脚底归到原点。** glTF 是米、FBX 是厘米,而 Mixamo 是从地面往上建骨架的。

上传前先看一眼输出,要盯的是身高合理(1.2~2.2m)、脚底约 0、贴图数非零:

```
24386148582032405.fbx  2.8 MB  3 mesh, 27429 tris, 15 textures, 15 mats rebuilt,
                               1 helpers dropped, height 1.67, feet at -0.000,
                               rig=removed, anim=stripped
```

### 第 2 步 · Mixamo(唯一需要手工操作的环节)

把 `out/` 里的 FBX 逐个传到 [mixamo.com](https://www.mixamo.com),放 6 个自动绑定标记点
(**A-pose 可以,不需要改成 T-pose**),然后下载:

- **格式:FBX Binary** —— 不要 FBX ASCII,不要 glTF
- **姿势:With Skin** —— "Without Skin" 是给纯动画下载用的,这条管线会直接拒绝那种文件

**下载后先改成你想要的名字再进下一步** —— 文件名会同时成为角色的显示名和资源 key。

### 第 3 步 · 绑定后的 FBX → App 角色

```bash
python3 tools/fbx_to_character.py rigged/Girl_D.fbx --key Girl_D
python3 tools/fbx_to_character.py rigged/*.fbx --all        # key 由文件名推导
```

产出落到 `assets_src/characters/`,也就是 `make_catalog.py` 读取的目录。

**这一步不能跳过**,两个原因都是静默失效的:

- `SCNScene(url:)` 只读 `.scn` 和 `.usdz`,**不读 FBX**。
- Mixamo 的骨骼名是 `mixamorig:Hips`(**冒号**),而 `BoneScheme.mixamo` 认的是 `mixamorig_Hips`
  (**下划线**)。那个下划线不是谁定的规范,而是 **USD 在净化 prim 名时把冒号替换掉的结果**。
  直接拿 Mixamo 的 FBX 用,`PoseRetargeter` 一根骨骼都找不到,音乐照放而角色全程停在绑定姿势。

`import_scene.fbx(automatic_bone_orientation=False)` 这个参数是关键:Blender 的自动定向会重写
bone roll,而重定向器是从骨骼**自身轴向**读取每根肢体的静止方向的,骨骼被重新定向过之后,
同一支舞在这个角色身上的结果就和其他角色不一样。

脚本会对两种常见错误直接报错:*no armature* 说明下载时选了 "Without Skin";
*mesh is not bound to the armature* 说明绑定没成功。

### 第 4 步 · 纹理压缩(别跳过)

```bash
swiftc -O tools/compress_textures.swift -o /tmp/compress_textures
/tmp/compress_textures assets_src/characters assets_src/characters/*.scn
```

Mixamo 下载回来的贴图是原尺寸,而角色模型**约 93% 的体积是贴图**:Remy 原来 58MB,其中 54MB 是
21 张未压缩 PNG(单张最大 6MB),而网格只有 1.9 万顶点。八个角色实测:**179MB → 32MB,-82%**。
另外 **Supabase 免费版单文件上限 50MB** —— Remy 58MB 就是因此传不上去的,这个脚本正是为它写的。

两个行为值得知道:

- **alpha 是扫描像素决定的,不看声明的通道。** Mixamo 的 PNG 不管有没有透明像素都是 RGBA,
  只看声明的话所有图都得留 PNG,只能压到 -64%。真正扫过像素后是 -90%,而真有镂空的贴图
  (头发、睫毛)仍然保留 PNG。
- **幂等。** 已压缩的贴图会被识别并跳过,重复跑不会 JPEG 转 JPEG 一次次劣化。

它还会施加 **roughness 抬底**(默认 0.45)。部分模型的 roughness 是**贴图**驱动的,
而 `sanitizeMaterials` 里那个下限只在 roughness 是标量时生效 —— 所以那些 authored 在 0.20~0.32
的贴图从来没被钳过,在舞台主光下就是一身湿塑料。

### 第 5 步 · 渲角色卡图

```bash
swiftc -O tools/render_thumbs.swift Animo3D/PoseRetargeter.swift Animo3D/MixamoBoneMap.swift \
    -o /tmp/render_thumbs
/tmp/render_thumbs characters assets_src/thumbs assets_src/characters/*.scn
```

没有卡图的话,角色栅格为了画一个格子就得先下载模型 —— 一屏出图前要 191MB。卡图每张约 40KB。

它会一起编译 App 自己的 `PoseRetargeter`,所以 `dances` 模式的预览不可能和舞台渲染漂移。
那个模式只是检查用的辅助,**不属于管线** —— App 的舞蹈卡是端上用内置角色 + clip 现渲的。

### 第 6 步 · 发布

见下面的[发布](#发布)。

---

## 新增舞蹈

**部分环节没有脚本 —— 排期前请先看这段。**

一支舞就是一个文件:`assets_src/dances/<Name>.json`,里面是源舞者 33 个关节世界坐标的逐帧采样,
由 `PoseRetargeter` 映射到当前表演的角色身上。**一支舞通用于所有角色**,
`make_catalog.py` 直接从里面读出时长。

缺口在于:**把 Mixamo FBX 采样成这份 JSON 的 Blender 脚本已经不存在了。** 它当时放在临时目录里,
后来丢了。仓库里那 44 支是用它产出的,但目前没有办法加第 45 支。重写它要做的是:逐帧读取
Mixamo 骨架上对应 BlazePose 那些关节的世界坐标,写成 `{fps, frames: [[[x,y,z], ...33]]}`。

重写时有两件事必须带上:

- 不同 Mixamo FBX 的骨骼名**数字前缀不一样**(`mixamorig9Hips` vs `mixamorigHips`),
  匹配前必须去掉 `^mixamorig\d*`。
- 纯动画 FBX(下载时选 "Without Skin")**没有 bind pose**,骨骼加载后是单位矩阵。
  静止姿势必须从一个带蒙皮的文件里取 —— 所有 Mixamo 骨架的静止姿势是同一个。

---

## 发布

```bash
python3 tools/make_catalog.py \
    --base-url "https://<project>.supabase.co/storage/v1/object/public/models/"
```

产出:

- `dist/index.json` —— 完整目录,约 7KB。`revision` 自动 +1。
- `dist/upload/` —— 和桶完全一致的目录树。把这个目录的**内容**(不是目录本身)拖进桶根。

```
dist/upload/index.json
dist/upload/characters/char_<Id>.scn
dist/upload/dances/mocap_<Id>.json
dist/upload/thumbs/thumb_<Id>.png
```

桶必须是 **Public**(Storage → 该桶 → Edit bucket → Public bucket)。
下面两个开关**保持关闭**:"Restrict file size" 会挡住较大的模型;`.scn` 通常被识别为
`application/octet-stream`,开 MIME 白名单会直接传不上去。

**签名 URL 是刻意不支持的。** URL 里带 token 就会过期,而已发布的版本无法自救 ——
到期那天 index 会对所有人同时失效。

### 什么进 index,什么不进

| | 位置 | 原因 |
|---|---|---|
| 角色模型 | 远端 | 大,而且会持续新增 |
| 舞蹈 clip | 远端 | 同上 |
| 角色卡图 | 远端 | 新增角色时必须能跟着下发 |
| **舞蹈卡图** | 都不在 | 端上用内置角色 + clip 现渲 |
| **音乐** | 内置 | 4 个固定文件;包内那份本来就优先命中,列进去只是白传 14MB |
| **内置角色 + 舞蹈** | 内置,并在 index 里声明 | 让首启零下载也能完整表演一支舞 |

`Res/builtin` 放的就是这一对,而 `make_catalog.py` **读那个目录**来填 index 的 `builtin` 字段。
它以前是两个手写的 Swift 常量,而且已经漂移了:舞蹈声明成 `Arms_Hip_Hop_Dance`,
包里的 clip 却是 `Hip_Hop_Dancing` —— 所以每一次首启的默认选择都在下载。

### 上传之后

index 的响应头是 `cache-control: max-age=3600`,所以重传后 CDN 上最长可能有一小时是旧的。
App 请求它时带了一个**按 5 分钟分桶的 cache-buster**,把这个窗口压到 5 分钟;
资源对象保持完整一小时缓存 —— 它们大且内容稳定。

注意 Supabase 面板**不会覆盖已存在的对象** —— 传新 index 之前要先**删掉桶里的 `index.json`**,
否则它会被静默跳过,App 继续读旧的 revision。

---

## 校验

```bash
swiftc -O tools/inspect_model.swift -o /tmp/inspect
/tmp/inspect assets_src/characters/Girl_D.scn
```

它会**用 App 完全相同的方式**通过 SceneKit 加载模型,报告它到底能不能用。一个在 Blender 或
预览里打开都正常的模型,进到 SceneKit 里仍然可能没有材质或骨架塌陷,而那只有从这里才看得见。

```
Girl_D.scn
  ok   rig: mixamo  nodes: 57  meshes: 2  skinned: 2
  ok   all 5 key bones present
  ok   2 materials, all textured
  ok   stands 1.51 m tall once upright
  ok   4.0 MB
```

- **`skinned: 0` 是致命的** —— 骨骼会动,身体不跟着动。
- **`rig: vrm`** 意味着骨骼名是 `J_Bip_*`,App 里已经没有任何代码读它了,必须过 Mixamo。

改动管线时的回归验证手法:**把仓库里已有的角色重新转一遍再对比。**
`X Bot` 走完第 1~3 步能精确复现出货的 `X_Bot.scn` —— 同样的 rig、2 网格 2 蒙皮、1.51m、4.0MB,
连鞋底偏移 0.1992 都一致。

---

## 约束与坑

- **`make_catalog.py` 只扫 `.scn`。** `fbx_to_character.py` 默认输出 `.scn`,走正常流程没问题;
  但用 `--format usdz` 产出的角色生成器看不到 —— 尽管 App 本身能正常加载 usdz。
- **Supabase 免费版单文件 50MB。** 记得跑纹理压缩。
- **App 已收敛到 Mixamo 单一路径。** VRM 的运行时部分(`VRoidClipPlayer`、`BoneScheme.vrm`、
  四元数 clip)全部移除。Mixamo 仍然是**动作素材的来源**,但只作为离线来源,不再是运行时格式。
- **Debug 和 Release 配了两个不同的 `DEVELOPMENT_TEAM`**,而 bundle id 相同。
  同一台设备上装了一个再装另一个会在签名主体上冲突。
- **代码里一律不出现中文** —— 注释、UI 文案、多语言都不要(多语言支持 en/de/es/fr/ja/ko/pt,
  刻意不含 zh-Hans)。**本文档这类给人看的说明文件不受此限。**

---

## 脚本速查

| 脚本 | 作用 |
|---|---|
| `glb_to_fbx.py` | `.vrm`/`.glb`/`.gltf` → 供 Mixamo 自动绑定的裸网格 FBX |
| `fbx_to_character.py` | Mixamo 绑定后的 FBX → `assets_src/characters/` 下的 `.scn`/`.usdz` |
| `compress_textures.swift` | 压缩 `.scn` 内嵌贴图;幂等;附带 roughness 抬底 |
| `render_thumbs.swift` | 离线卡图(`characters` 模式进管线;`dances` 模式只是预览辅助) |
| `inspect_model.swift` | 用 App 的方式加载模型并报告是否可用 |
| `make_catalog.py` | 按磁盘现状生成 `index.json` 和上传目录树 |
| `make_sky.py` | 从一张照片生成户外天空全景图(2:1 等距柱状) |
| `make_icon.swift` | App 图标 |
| `make_promo.swift` | App Store 截图;产物不进包 |
