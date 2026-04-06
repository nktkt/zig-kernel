// Matrix — 4x4 行列演算 (16.16 固定小数点)
// 3D 変換行列, ベクトル演算, 行列式, 正弦テーブル利用回転
// freestanding 環境向け: 浮動小数点なし

const vga = @import("vga.zig");
const fmt = @import("fmt.zig");
const math = @import("math.zig");
const serial = @import("serial.zig");

// ---- 固定小数点ヘルパー ----

const FP = math.FixedPoint;
const FRAC_BITS: u5 = 16;
const ONE: i32 = 1 << FRAC_BITS; // 65536

fn fpMul(a: i32, b: i32) i32 {
    const product = @as(i64, a) * @as(i64, b);
    return @truncate(product >> FRAC_BITS);
}

fn fpDiv(a: i32, b: i32) i32 {
    if (b == 0) return 0;
    const shifted = @as(i64, a) << FRAC_BITS;
    return @truncate(@divTrunc(shifted, @as(i64, b)));
}

fn fpFromInt(val: i32) i32 {
    return val << FRAC_BITS;
}

fn fpToInt(val: i32) i32 {
    return val >> FRAC_BITS;
}

// ---- 3D ポイント / ベクトル ----

pub const Point3D = struct {
    x: i32 = 0, // 16.16 固定小数点
    y: i32 = 0,
    z: i32 = 0,
};

pub const Vector3D = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,

    /// ベクトル加算
    pub fn add(self: Vector3D, other: Vector3D) Vector3D {
        return .{
            .x = self.x + other.x,
            .y = self.y + other.y,
            .z = self.z + other.z,
        };
    }

    /// ベクトル減算
    pub fn sub(self: Vector3D, other: Vector3D) Vector3D {
        return .{
            .x = self.x - other.x,
            .y = self.y - other.y,
            .z = self.z - other.z,
        };
    }

    /// スカラー倍
    pub fn scale(self: Vector3D, s: i32) Vector3D {
        return .{
            .x = fpMul(self.x, s),
            .y = fpMul(self.y, s),
            .z = fpMul(self.z, s),
        };
    }

    /// 内積
    pub fn dot(self: Vector3D, other: Vector3D) i32 {
        return fpMul(self.x, other.x) + fpMul(self.y, other.y) + fpMul(self.z, other.z);
    }

    /// 外積
    pub fn cross(self: Vector3D, other: Vector3D) Vector3D {
        return .{
            .x = fpMul(self.y, other.z) - fpMul(self.z, other.y),
            .y = fpMul(self.z, other.x) - fpMul(self.x, other.z),
            .z = fpMul(self.x, other.y) - fpMul(self.y, other.x),
        };
    }

    /// ベクトルの長さの二乗 (16.16)
    pub fn lengthSquared(self: Vector3D) i32 {
        return self.dot(self);
    }

    /// ベクトルの長さ (近似: 整数の平方根を使用)
    pub fn length(self: Vector3D) i32 {
        const lsq = self.lengthSquared();
        if (lsq <= 0) return 0;
        // lsq は 16.16 * 16.16 >> 16 = 16.16 の二乗
        // 平方根は精度が落ちるが近似
        const lsq_u: u32 = @intCast(if (lsq < 0) -lsq else lsq);
        const sqrt_val = math.sqrt_int(lsq_u);
        // 結果を 16.16 形式に調整
        return @intCast(sqrt_val);
    }

    /// 正規化 (近似)
    pub fn normalize(self: Vector3D) Vector3D {
        const len = self.length();
        if (len == 0) return self;
        return .{
            .x = fpDiv(self.x, len),
            .y = fpDiv(self.y, len),
            .z = fpDiv(self.z, len),
        };
    }

    /// 否定
    pub fn negate(self: Vector3D) Vector3D {
        return .{ .x = -self.x, .y = -self.y, .z = -self.z };
    }

    /// 整数値からベクトルを生成
    pub fn fromInts(x: i32, y: i32, z: i32) Vector3D {
        return .{
            .x = fpFromInt(x),
            .y = fpFromInt(y),
            .z = fpFromInt(z),
        };
    }
};

// ---- 4x4 行列 ----

pub const Matrix4x4 = struct {
    // 行優先: m[row][col]
    m: [4][4]i32 = [4][4]i32{
        [4]i32{ 0, 0, 0, 0 },
        [4]i32{ 0, 0, 0, 0 },
        [4]i32{ 0, 0, 0, 0 },
        [4]i32{ 0, 0, 0, 0 },
    },

    /// 単位行列
    pub fn identity() Matrix4x4 {
        return .{ .m = .{
            .{ ONE, 0, 0, 0 },
            .{ 0, ONE, 0, 0 },
            .{ 0, 0, ONE, 0 },
            .{ 0, 0, 0, ONE },
        } };
    }

    /// ゼロ行列
    pub fn zero() Matrix4x4 {
        return .{};
    }

    /// 行列加算
    pub fn add(a: Matrix4x4, b: Matrix4x4) Matrix4x4 {
        var result: Matrix4x4 = .{};
        for (0..4) |row| {
            for (0..4) |col| {
                result.m[row][col] = a.m[row][col] + b.m[row][col];
            }
        }
        return result;
    }

    /// 行列減算
    pub fn subtract(a: Matrix4x4, b: Matrix4x4) Matrix4x4 {
        var result: Matrix4x4 = .{};
        for (0..4) |row| {
            for (0..4) |col| {
                result.m[row][col] = a.m[row][col] - b.m[row][col];
            }
        }
        return result;
    }

    /// 行列乗算
    pub fn multiply(a: Matrix4x4, b: Matrix4x4) Matrix4x4 {
        var result: Matrix4x4 = .{};
        for (0..4) |row| {
            for (0..4) |col| {
                var sum: i32 = 0;
                for (0..4) |k| {
                    sum += fpMul(a.m[row][k], b.m[k][col]);
                }
                result.m[row][col] = sum;
            }
        }
        return result;
    }

    /// 転置
    pub fn transpose(mat: Matrix4x4) Matrix4x4 {
        var result: Matrix4x4 = .{};
        for (0..4) |row| {
            for (0..4) |col| {
                result.m[row][col] = mat.m[col][row];
            }
        }
        return result;
    }

    /// スカラー倍
    pub fn scaleMat(mat: Matrix4x4, factor: i32) Matrix4x4 {
        var result: Matrix4x4 = .{};
        for (0..4) |row| {
            for (0..4) |col| {
                result.m[row][col] = fpMul(mat.m[row][col], factor);
            }
        }
        return result;
    }

    /// スケーリング行列
    pub fn scaleMatrix(sx: i32, sy: i32, sz: i32) Matrix4x4 {
        var result = identity();
        result.m[0][0] = sx;
        result.m[1][1] = sy;
        result.m[2][2] = sz;
        return result;
    }

    /// 平行移動行列
    pub fn translate(x: i32, y: i32, z: i32) Matrix4x4 {
        var result = identity();
        result.m[0][3] = x;
        result.m[1][3] = y;
        result.m[2][3] = z;
        return result;
    }

    /// X 軸回転行列 (角度は sinTable のインデックス, 0-63 = 0-360度)
    pub fn rotateX(angle: u32) Matrix4x4 {
        const s = math.sin(angle).raw;
        const c = math.cos(angle).raw;

        var result = identity();
        result.m[1][1] = c;
        result.m[1][2] = -s;
        result.m[2][1] = s;
        result.m[2][2] = c;
        return result;
    }

    /// Y 軸回転行列
    pub fn rotateY(angle: u32) Matrix4x4 {
        const s = math.sin(angle).raw;
        const c = math.cos(angle).raw;

        var result = identity();
        result.m[0][0] = c;
        result.m[0][2] = s;
        result.m[2][0] = -s;
        result.m[2][2] = c;
        return result;
    }

    /// Z 軸回転行列
    pub fn rotateZ(angle: u32) Matrix4x4 {
        const s = math.sin(angle).raw;
        const c = math.cos(angle).raw;

        var result = identity();
        result.m[0][0] = c;
        result.m[0][1] = -s;
        result.m[1][0] = s;
        result.m[1][1] = c;
        return result;
    }

    /// ポイントを変換
    pub fn transformPoint(mat: Matrix4x4, x: i32, y: i32, z: i32) Point3D {
        return .{
            .x = fpMul(mat.m[0][0], x) + fpMul(mat.m[0][1], y) + fpMul(mat.m[0][2], z) + mat.m[0][3],
            .y = fpMul(mat.m[1][0], x) + fpMul(mat.m[1][1], y) + fpMul(mat.m[1][2], z) + mat.m[1][3],
            .z = fpMul(mat.m[2][0], x) + fpMul(mat.m[2][1], y) + fpMul(mat.m[2][2], z) + mat.m[2][3],
        };
    }

    /// ベクトルを変換 (平行移動なし)
    pub fn transformVector(mat: Matrix4x4, v: Vector3D) Vector3D {
        return .{
            .x = fpMul(mat.m[0][0], v.x) + fpMul(mat.m[0][1], v.y) + fpMul(mat.m[0][2], v.z),
            .y = fpMul(mat.m[1][0], v.x) + fpMul(mat.m[1][1], v.y) + fpMul(mat.m[1][2], v.z),
            .z = fpMul(mat.m[2][0], v.x) + fpMul(mat.m[2][1], v.y) + fpMul(mat.m[2][2], v.z),
        };
    }

    /// 3x3 行列式 (余因子展開の部分)
    fn det3x3(m00: i32, m01: i32, m02: i32, m10: i32, m11: i32, m12: i32, m20: i32, m21: i32, m22: i32) i32 {
        return fpMul(m00, fpMul(m11, m22) - fpMul(m12, m21)) -
            fpMul(m01, fpMul(m10, m22) - fpMul(m12, m20)) +
            fpMul(m02, fpMul(m10, m21) - fpMul(m11, m20));
    }

    /// 4x4 行列式
    pub fn determinant(mat: Matrix4x4) i32 {
        var det: i32 = 0;

        // 第一行で余因子展開
        det += fpMul(mat.m[0][0], det3x3(
            mat.m[1][1],
            mat.m[1][2],
            mat.m[1][3],
            mat.m[2][1],
            mat.m[2][2],
            mat.m[2][3],
            mat.m[3][1],
            mat.m[3][2],
            mat.m[3][3],
        ));
        det -= fpMul(mat.m[0][1], det3x3(
            mat.m[1][0],
            mat.m[1][2],
            mat.m[1][3],
            mat.m[2][0],
            mat.m[2][2],
            mat.m[2][3],
            mat.m[3][0],
            mat.m[3][2],
            mat.m[3][3],
        ));
        det += fpMul(mat.m[0][2], det3x3(
            mat.m[1][0],
            mat.m[1][1],
            mat.m[1][3],
            mat.m[2][0],
            mat.m[2][1],
            mat.m[2][3],
            mat.m[3][0],
            mat.m[3][1],
            mat.m[3][3],
        ));
        det -= fpMul(mat.m[0][3], det3x3(
            mat.m[1][0],
            mat.m[1][1],
            mat.m[1][2],
            mat.m[2][0],
            mat.m[2][1],
            mat.m[2][2],
            mat.m[3][0],
            mat.m[3][1],
            mat.m[3][2],
        ));

        return det;
    }

    /// 行列の等価判定
    pub fn equals(a: Matrix4x4, b: Matrix4x4) bool {
        for (0..4) |row| {
            for (0..4) |col| {
                if (a.m[row][col] != b.m[row][col]) return false;
            }
        }
        return true;
    }

    /// 行列を VGA に表示
    pub fn printMatrix(mat: Matrix4x4) void {
        for (0..4) |row| {
            vga.write("  | ");
            for (0..4) |col| {
                const fp = FP.fromRaw(mat.m[row][col]);
                math.printFixedPoint(fp);
                vga.write("  ");
            }
            vga.write("|\n");
        }
    }
};

// ---- ベクトル表示 ----

pub fn printVector(v: Vector3D) void {
    vga.putChar('(');
    math.printFixedPoint(FP.fromRaw(v.x));
    vga.write(", ");
    math.printFixedPoint(FP.fromRaw(v.y));
    vga.write(", ");
    math.printFixedPoint(FP.fromRaw(v.z));
    vga.putChar(')');
}

pub fn printPoint(p: Point3D) void {
    vga.putChar('(');
    math.printFixedPoint(FP.fromRaw(p.x));
    vga.write(", ");
    math.printFixedPoint(FP.fromRaw(p.y));
    vga.write(", ");
    math.printFixedPoint(FP.fromRaw(p.z));
    vga.putChar(')');
}

// ---- デモ ----

pub fn demo() void {
    vga.setColor(.yellow, .black);
    vga.write("=== Matrix Demo ===\n");
    vga.setColor(.light_grey, .black);

    // 単位行列
    vga.write("Identity:\n");
    const id = Matrix4x4.identity();
    Matrix4x4.printMatrix(id);

    // 平行移動
    vga.write("\nTranslate(2, 3, 4):\n");
    const t = Matrix4x4.translate(fpFromInt(2), fpFromInt(3), fpFromInt(4));
    Matrix4x4.printMatrix(t);

    // ポイント変換
    vga.write("\nTransform (1,0,0) by Translate(2,3,4): ");
    const p = t.transformPoint(fpFromInt(1), fpFromInt(0), fpFromInt(0));
    printPoint(p);
    vga.putChar('\n');

    // 回転
    vga.write("\nRotateZ(16) [=90 degrees]:\n");
    const rz = Matrix4x4.rotateZ(16);
    Matrix4x4.printMatrix(rz);

    // 行列乗算: 回転 * 平行移動
    vga.write("\nRotateZ * Translate:\n");
    const rt = Matrix4x4.multiply(rz, t);
    Matrix4x4.printMatrix(rt);

    // 行列式
    vga.write("\nDeterminant(Identity) = ");
    const det = Matrix4x4.determinant(id);
    math.printFixedPoint(FP.fromRaw(det));
    vga.putChar('\n');

    // ベクトル演算
    vga.write("\nVector operations:\n");
    const v1 = Vector3D.fromInts(1, 0, 0);
    const v2 = Vector3D.fromInts(0, 1, 0);

    vga.write("  v1 = ");
    printVector(v1);
    vga.write(", v2 = ");
    printVector(v2);
    vga.putChar('\n');

    vga.write("  dot(v1,v2) = ");
    math.printFixedPoint(FP.fromRaw(v1.dot(v2)));
    vga.putChar('\n');

    vga.write("  cross(v1,v2) = ");
    printVector(v1.cross(v2));
    vga.putChar('\n');

    vga.write("  v1+v2 = ");
    printVector(v1.add(v2));
    vga.putChar('\n');

    // スケーリング
    vga.write("\nScale(2,3,1):\n");
    const sm = Matrix4x4.scaleMatrix(fpFromInt(2), fpFromInt(3), fpFromInt(1));
    Matrix4x4.printMatrix(sm);
}

pub fn printInfo() void {
    vga.setColor(.yellow, .black);
    vga.write("Matrix Module:\n");
    vga.setColor(.light_grey, .black);
    vga.write("  4x4 matrices with 16.16 fixed-point\n");
    vga.write("  Operations: multiply, transpose, rotate, translate, determinant\n");
    vga.write("  Vector3D: dot, cross, normalize, length\n");
}
