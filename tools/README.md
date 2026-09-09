# 资源管线

App 运行时加载的一切都来自一个地方:**Supabase 桶里的 `index.json`**。除此之外没有第二份配置文件,
也没有任何需要手工登记的清单。这个目录里的脚本负责:把一个源模型或源舞蹈,变成 App 能加载的东西,
然后重新生成那份 index。

```
VRM/VRoid 模型 (.vrm/.glb) ──── auto_rig.py ─────────────▶ 绑定后 FBX
                                                                 │
无骨架模型 (Tripo3D/扫描件)  glb_to_fbx.py ─▶ 裸网格 FBX          │
                                                │                │
                                        [ mixamo.com ] ──────────┤
                                                                 │
                                             fbx_to_character.py ┤
                                                                 ▼
源舞蹈 (Mixamo .fbx)      fbx_to_mocap.py ─▶ mocap JSON   assets_src/characters/*.scn
                                                 │               │
                                                 │    compress_textures.swift
                                                 │    render_thumbs.swift
                                                 ▼               ▼
                                          make_catalog.py ──▶ dist/index.json
                                                              dist/upload/
```

**两条角色路线,按源模型有没有骨架分。** VRM/VRoid 自带完整人形骨架和作者画好的蒙皮,
`auto_rig.py` 只需要把骨骼改名就能直接用,一条命令、几秒钟,mixamo.com 完全不用碰。
没有骨架的模型(Tripo3D 生成、三维扫描)仍然只能走 Mixamo 的自动绑定 —— 那是这套管线里
**唯一**剩下的手工环节。

所有信息都从磁盘上真实存在的文件推导。没有白名单,也没有显示名对照表 —— **文件名就是名字**,
`The_Boss.scn` 在 App 里显示为 "The Boss"。想改显示名就改文件名。

---

## 新增角色 · VRM/VRoid(自动,推荐)

### 第 1 步 · 源模型 → 绑定后 FBX(一条命令)

```bash
python3 tools/auto_rig.py path/to/model.vrm -o rigged/Girl_D.fbx --albedo-gain 0.6
python3 tools/auto_rig.py tools/glb/*.glb -o rigged/ --albedo-gain 0.6      # 批量
```

七个 VRoid 实测:总共 6.5 秒,`all 19 required present`。

**为什么改个名字就够了。** VRM 的人形骨架是固定标准,`BoneScheme.mixamo` 要的 19 根和它严格一对一
(`J_Bip_C_Hips` → `mixamorig_Hips`、`J_Bip_L_UpperArm` → `mixamorig_LeftArm` …)。而 `PoseRetargeter`
是从「骨→子骨」的世界方向取静止朝向、再套 `delta * restWorldOrient`,骨骼 roll、骨长、A-pose 还是
T-pose 都不进结果 —— **只有名字要对上**。顺带保住了作者手绘的蒙皮权重,Mixamo 是重新解算的,
这就是它有时会把裙子跟着大腿拖走的原因。

四个不显眼但会静默出错的地方,脚本都处理了:

- **贴图必须先落到唯一路径再导出。** glTF 导入的图 `filepath` 是空的,而 FBX 导出器按 filepath 的
  basename 命名内嵌贴图 —— 空名全撞成一个文件。实测:31 张图全部解析到 `_10`(2048 的身体图),
  脸和头发在用身体的 UV 采样,而且**渲染出来"看着还行"**,不逐个材质比对根本发现不了。
- **`add_leaf_bones=True`**,和 `glb_to_fbx.py` 相反。VRM 的骨架末端就是 ToeBase 和每根指尖,而
  `fbx_to_character.py` 用 `ignore_leaf_bones=True` 导入,不给它们写出 `_end` 子骨就会被当叶子丢掉,
  `BoneScheme` 的 leftToe/rightToe 一没,踩地判定就废了。Mixamo 自己的骨架有 `Toe_End`,同一个道理。
- **`--albedo-gain`(线性光下乘系数)。** MToon 是 unlit 着色器,明暗**画在贴图里**,数值落在 PBR
  期待放反射率的位置上,而且上面没有余量了 —— 实测脸部皮肤 albedo 均值 0.913、99.8% 的像素 ≥0.85
  (现实里最白的石膏才 0.9),八个 Mixamo 角色是 0.22~0.49、0~10%。**灯还没开它就在裁剪点上**,
  调曝光救不回来,缺的是资产的余量。0.6 把七个模型全带回 0.35~0.50 / ≤5.5%,正好落在 Mixamo 那批
  区间内。注意这是**烘进贴图、不可逆**的。
- **朝向、落地、材质重建**全部复用 `glb_to_fbx.py` 的同一份函数(直接 import),所以两条路产出的
  角色站位和朝向一致,不会漂。

拿不准就先看输出行:身高 1.2~2.2、feet at 0、`all 19 required present`、贴图数非零。

### 第 2 步 · 绑定后的 FBX → App 角色

跳到下面的[「绑定后的 FBX → App 角色」](#绑定后的-fbx--app-角色),之后的步骤两条路完全一样。

---

## 新增角色 · 没有骨架的模型(仍需 Mixamo)

Tripo3D 生成的、三维扫描的、任何不带骨架的网格走这条。`auto_rig.py` 会直接报错拒绝这类文件,
它不猜骨架位置。

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
- **源模型背对镜头时转 180°。** Mixamo 预览和绑定的是朝 FBX **+Z** 的角色。而 VRM 朝 glTF +Z,
  被 Blender 的 glTF 导入器映射成 Blender +Y,再经标准 FBX 导出映射成 **−Z** —— 正好反了,
  所以每个 VRoid 上传都是背对着 Mixamo,**那 6 个绑定标记点会全放到错误的一侧**。
  这比"看着别扭"严重,是会导致绑定结果错误的。Mixamo 自己的模型本来朝向就对,不会被动。

  判别依据是**骨骼名**(`J_Bip_*` = VRM、`mixamorig*` = Mixamo),在剥掉骨架**之前**读。
  几何依据在这里行不通:"脚趾朝前"对 T-pose 成立、对已摆姿势的模型失效 —— 实测同为 Mixamo 骨架,
  T-pose 的 X Bot 指向 −Y,而处于跳舞姿势的 Strut Walking 指向 +Y,两者矛盾。
  识别不出的骨架不会被转,但会打印警告;用 `--face-flip` / `--no-face-flip` 手动覆盖。

上传前先看一眼输出,要盯的是身高合理(1.2~2.2m)、脚底约 0、贴图数非零:

```
24386148582032405.fbx  2.8 MB  3 mesh, 27429 tris, 15 textures, 15 mats rebuilt,
                               1 helpers dropped, height 1.67, feet at -0.000,
                               src rig=vrm, faced=turned, rig=removed, anim=stripped
```

`faced=turned` 表示做了朝向翻转;`faced=as-is` 表示判定为本来就朝对了。

### 第 2 步 · Mixamo(唯一需要手工操作的环节)

把 `out/` 里的 FBX 逐个传到 [mixamo.com](https://www.mixamo.com),放 6 个自动绑定标记点
(**A-pose 可以,不需要改成 T-pose**),然后下载:

- **格式:FBX Binary** —— 不要 FBX ASCII,不要 glTF
- **姿势:With Skin** —— "Without Skin" 是给纯动画下载用的,这条管线会直接拒绝那种文件

**上传后先看一眼 Mixamo 的预览:应该是正脸。** 如果看到的是后脑勺,说明朝向判别在这个模型上没生效,
用 `--face-flip` 重新转一遍再传。背对着放标记点会得到一个绑错的骨架,而那要等到进 App 跳起来才看得出。

**下载后先改成你想要的名字再进下一步** —— 文件名会同时成为角色的显示名和资源 key。

### 第 3 步 · 绑定后的 FBX → App 角色
<a id="绑定后的-fbx--app-角色"></a>

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

> **另一条没有实现的路(仅备忘)**
>
> VRoid 模型自带完整骨架和蒙皮,唯一不能用的原因是骨骼名。而 VRM 的人形骨骼是固定标准,
> 和 `BoneScheme.mixamo` 需要的 19 根是严格一对一的 —— 已实测确认全部存在
> (`J_Bip_C_Hips`、`J_Bip_L_UpperArm`、`J_Bip_L_ToeBase` …)。
> 所以理论上可以**离线改骨骼名**,保留原生蒙皮、完全跳过 Mixamo,把 7 次手工操作变成 1 条命令。
>
> 可行性有历史证据:项目里原来就有 `BoneScheme.vrm`,`PoseRetargeter` 当时就是用 Mixamo 的
> mocap 位置数据驱动 VRoid 骨骼的,而重定向器是 body-frame 局部坐标系、与骨骼朝向无关的设计。
>
> **目前没有实现**,记在这里是因为它影响排期判断:如果角色数量继续增长,这条路省掉的手工成本是线性的。

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

一支舞就是一个文件:`assets_src/dances/<Name>.json`,里面是源舞者 33 个关节世界坐标的逐帧采样,
由 `PoseRetargeter` 映射到当前表演的角色身上。**一支舞通用于所有角色**,
`make_catalog.py` 直接从里面读出时长。

### 第 1 步 · 从 Mixamo 下载

下载弹窗:

| 项 | 选什么 |
|---|---|
| Format | **FBX Binary(.fbx)** |
| Skin | **Without Skin** |
| Frames per Second | **30** |
| Keyframe Reduction | **none** |

角色页上的 **In Place 不要勾**。

依据是量现存语料得出的:44 支 fps 全是 30;水平位移中位数 0.52m、最大 2.28m,所以当初就不是
In Place,而 retargeter 是拿本支舞自己的首帧当位移基准的。Keyframe Reduction 必须关 —— 这是
**逐帧采样**的格式,丢掉的帧没有地方插值补回来。

### 第 2 步 · FBX → mocap JSON

```bash
python3 tools/fbx_to_mocap.py "Salsa Dancing.fbx"          # -> assets_src/dances/Salsa_Dancing.json
python3 tools/fbx_to_mocap.py downloads/*.fbx              # 批量
python3 tools/fbx_to_mocap.py --check assets_src/dances/*.json   # 只校验
```

**文件名就是舞蹈显示名。** 浏览器的重名后缀会转成语料自己的写法:`Hip Hop Dancing (7).fbx` →
`Hip_Hop_Dancing_7`(仓库里本来就有 `Dancing_1`、`Swing_Dancing_4` 这种)。丢掉那个数字的话,
一个下载目录里的每一支 `Hip Hop Dancing (n)` 都会覆盖前一支。

转完会自动拿产物对着现存语料做一致性校验,不过关会指出具体哪一项。

格式的每一条都是量出来的,不是猜的:

- **33 个槽位里只有 12 个有值** —— 11~16(肩肘腕)、23~28(胯膝踝),另外 21 个是零占位,
  编号来自 BlazePose(摄像头那条路会填满 33 个)。翻遍 8 支的每一帧,没有第 13 个索引非零过。
- **Z 轴向上**:踝 0.15、胯 0.84、肩 1.45,x/y 跨在零两侧。那就是 Blender 自己的世界坐标,
  FBX 导入器直接给的,不用转轴。
- **米制**。Mixamo 写的是厘米,Blender 导入器按 0.01 缩放。
- **位移保留**,理由见上。

两个坑,脚本都处理了:

- Mixamo 的骨骼名不总是一样:`mixamorig:Hips`、`mixamorigHips`、`mixamorig9Hips` 都出现过,
  匹配前用 `^mixamorig[:_]?\d*` 剥掉前缀。
- "Without Skin" 的 FBX 没有 bind pose。这个脚本用不到 —— 它读的是**每帧姿态骨架的世界坐标**;
  真碰到 rest 塌掉的文件,改下 "With Skin" 就绕开了。

### 第 3 步 · 源骨架比例的影响(知道就行,不用处理)

Mixamo 下载动画时用的是**当前选中角色的骨架**,换个角色比例就变。实测:仓库那 44 支躯干长度
0.54~0.64,另一批下载是 0.29~0.33 —— 短一半。`PoseRetargeter` 的髋部位移是按躯干长度归一化的,
所以短躯干那批的髋部起伏会被放大约 1.9 倍。上机看不出问题(反而更贴地),肢体姿态因为只用方向
所以完全一致 —— 但如果哪天发现某批舞"晃得比别的厉害",这里是原因。

### 第 4 步 · 内置那支要跟着换

`Animo3D/Res/builtin/mocap_<Id>.json` 是打进 App 包里的离线兜底,`make_catalog.py` 从这个目录
读出 `builtin` 写进 index。**App 取资源是包内优先**,所以换掉 `assets_src/dances/` 里的同名文件
而不换包内那份,结果是「卡片按 index 写 6 秒、实际放包内那支 18.6 秒」。换完必须重新出包,
只传桶不生效。

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
- **`rig: vrm`** 意味着骨骼名还是 `J_Bip_*` —— App 里已经没有任何代码读它了。
  这说明 `auto_rig.py` 那一步被跳过了(或者拿 `glb_to_fbx.py --keep-rig` 直接转的),重跑 `auto_rig.py`。

改动管线时的回归验证手法:**把仓库里已有的角色重新转一遍再对比。**
`X Bot` 走完第 1~3 步能精确复现出货的 `X_Bot.scn` —— 同样的 rig、2 网格 2 蒙皮、1.51m、4.0MB,
连鞋底偏移 0.1992 都一致。

---

## 约束与坑

- **`make_catalog.py` 只扫 `.scn`。** `fbx_to_character.py` 默认输出 `.scn`,走正常流程没问题;
  但用 `--format usdz` 产出的角色生成器看不到 —— 尽管 App 本身能正常加载 usdz。
- **Supabase 免费版单文件 50MB。** 记得跑纹理压缩。
- **App 运行时只认 Mixamo 骨骼名这一种。** VRM 的运行时部分(`VRoidClipPlayer`、`BoneScheme.vrm`、
  四元数 clip)全部移除。VRM 模型仍然能用,但改名发生在**离线**的 `auto_rig.py` 里,进 App 的
  永远是 `mixamorig_*`。Mixamo 也仍然是动作素材的来源,同样只在离线这一侧。
- **Debug 和 Release 配了两个不同的 `DEVELOPMENT_TEAM`**,而 bundle id 相同。
  同一台设备上装了一个再装另一个会在签名主体上冲突。
- **代码里一律不出现中文** —— 注释、UI 文案、多语言都不要(多语言支持 en/de/es/fr/ja/ko/pt,
  刻意不含 zh-Hans)。**本文档这类给人看的说明文件不受此限。**

---

## 脚本速查

| 脚本 | 作用 |
|---|---|
| `auto_rig.py` | VRM/VRoid → Mixamo 命名的绑定后 FBX(**替代 glb_to_fbx + mixamo.com 两步**);`--albedo-gain` 压 MToon 过亮的贴图 |
| `glb_to_fbx.py` | `.vrm`/`.glb`/`.gltf` → 供 Mixamo 自动绑定的裸网格 FBX(只有**没骨架**的模型才需要) |
| `fbx_to_character.py` | 绑定后的 FBX → `assets_src/characters/` 下的 `.scn`/`.usdz` |
| `fbx_to_mocap.py` | Mixamo 动画 FBX → `assets_src/dances/` 下的 mocap JSON;`--check` 校验现有文件 |
| `compress_textures.swift` | 压缩 `.scn` 内嵌贴图;幂等;附带 roughness 抬底 |
| `render_thumbs.swift` | 离线卡图(`characters` 模式进管线;`dances` 模式只是预览辅助) |
| `inspect_model.swift` | 用 App 的方式加载模型并报告是否可用 |
| `make_catalog.py` | 按磁盘现状生成 `index.json` 和上传目录树 |
| `make_sky.py` | 从一张照片生成户外天空全景图(2:1 等距柱状) |
| `make_icon.swift` | App 图标 |
| `make_promo.swift` | App Store 截图;产物不进包 |
