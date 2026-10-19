#include <metal_stdlib>
using namespace metal;
// Double-single arithmetic: Metal has no native FP64. Disable fast math in
// compile options; fma retains the product residual explicitly.
struct DS { float h, l; };
DS ds(float x) { return {x, 0}; }
DS add(DS a, DS b) {
    float s = a.h + b.h, v = s - a.h;
    float e = (a.h - (s-v)) + (b.h-v) + a.l + b.l;
    float h = s + e; return {h, e - (h-s)};
}
DS neg(DS a) { return {-a.h, -a.l}; }
DS sub(DS a, DS b) { return add(a, neg(b)); }
DS mul(DS a, DS b) {
    float h = a.h * b.h;
    float l = fma(a.h, b.h, -h) + a.h*b.l + a.l*b.h;
    float s = h + l; return {s, l - (s-h)};
}
DS times(DS a, float b) { return mul(a, ds(b)); }
struct CX { DS x, y; };
CX cx(float x, float y) { return {ds(x), ds(y)}; }
CX cadd(CX a, CX b) { return {add(a.x,b.x), add(a.y,b.y)}; }
CX product(CX a, CX b) { return {sub(mul(a.x,b.x),mul(a.y,b.y)), add(mul(a.x,b.y),mul(a.y,b.x))}; }
CX times(CX a, float b) { return {times(a.x,b), times(a.y,b)}; }
CX shift(CX a, int e) { return {{ldexp(a.x.h,e),ldexp(a.x.l,e)}, {ldexp(a.y.h,e),ldexp(a.y.l,e)}}; }
float norm(CX a) { return a.x.h*a.x.h + a.y.h*a.y.h; }
float mag(CX a) { return max(abs(a.x.h),abs(a.y.h)); }
CX unpack(float4 a) { return {{a.x,a.y},{a.z,a.w}}; }
struct Params {
    uint width, height, limit, count;
    float4 center;
    float2 mantissa;
    int exponent;
    uint shallow;
    uint palette, first_row, row_count, padding;
    float4 coefficient;
    int coefficient_exponent;
    uint start, leaves, reserved1;
};
float escape_value(uint n, float r2) { return float(n) + 1.0f - log2(log(sqrt(r2))); }
// Accept only when the entire propagated error ball has escaped and its
// smooth-color interval is narrower than 0.001 iterations (palette step ~0.0094).
// A large intermediate error need not imply a visible error at escape.
float checked_escape(uint n, float r2, float error) {
    float r=sqrt(r2), lo=r-error, hi=r+error;
    if (lo<=16 || !isfinite(error)) return -2;
    if (log2(log(hi)/log(lo))>0.001f) return -2;
    return escape_value(n,r2);
}
float direct(CX c, uint limit) {
    // Conservative interior tests. Keep a margin outside roundoff.
    float x = c.x.h, y = c.y.h, q = (x-0.25f)*(x-0.25f)+y*y;
    if (q*(q+x-0.25f) < 0.25f*y*y - 1e-6f || (x+1)*(x+1)+y*y < 0.0625f-1e-6f) return -1;
    CX z = cx(0,0);
    float error_bound=0;
    for (uint i=0; i<limit; ++i) {
        float zn=norm(z);
        error_bound=2*sqrt(zn)*error_bound+error_bound*error_bound+2e-14f*(zn+mag(c));
        z = cadd(product(z,z),c);
        float r2=norm(z);
        if (!isfinite(error_bound)) return -2;
        if (r2>256) return checked_escape(i+1,r2,error_bound);
        if (sqrt(r2)+error_bound>=16 || error_bound>1) return -2;
    }
    return -1;
}
struct BLA { float4 a, b; float radius, quadratic, gain; uint steps; };
float perturb(device const float4* orbit, CX dc, int base, constant Params& p) {
    CX w=cx(0,0), d=dc;
    int e=base;
    float scale=ldexp(1.0f,e);
    uint r=p.start;
    float error_bound=0;
    if (p.start>0) {
        w=product(unpack(p.coefficient),dc); e=base+p.coefficient_exponent;
        scale=ldexp(1.0f,e); d=shift(dc,base-e);
        error_bound=mag(w)*2e-13f;
    }
    for (uint i=p.start; i<p.limit; ++i) {
        if (r+1>=p.count) return -2;
        CX z=unpack(orbit[r]);
        if (r!=0 && mag(z)<1e-30f) return -2;
        float wm=mag(w), zm=mag(z);
        error_bound=2*sqrt(norm(cadd(z,times(w,scale))))*error_bound+scale*error_bound*error_bound+2e-14f*(2*zm*wm+scale*wm*wm+mag(d));
        w=cadd(cadd(times(product(z,w),2),times(product(w,w),scale)),d);
        ++r;
        float m=mag(w);
        if (!isfinite(m)) return -2;
        if (m>0 && (m>65536 || m<0.0000152587890625f)) {
            int k; frexp(m,k);
            w=shift(w,-k); error_bound=ldexp(error_bound,-k); e+=k;
            scale=ldexp(1.0f,e); d=shift(dc,base-e);
        }
        CX dz=times(w,scale), ref=unpack(orbit[r]), total=cadd(ref,dz);
        float r2=norm(total);
        if (!isfinite(r2) || !isfinite(error_bound)) return -2;
        float total_error=error_bound*scale+2e-14f*mag(ref);
        if (r2>256) return checked_escape(i+1,r2,total_error);
        if (sqrt(r2)+total_error>=16 || total_error>1) return -2;
        // Suspect cancellation is refined in FP64, then MPFR if necessary.
        if (r2<1e-10f*norm(ref)) return -2;
        if (r2<norm(dz) || r+1==p.count) {
            error_bound=total_error+2e-14f*mag(total);
            r=0; w=total; e=0; scale=1; d=shift(dc,base);
            float m=mag(w);
            if (m>0) {
                int k; frexp(m,k);
                w=shift(w,-k); error_bound=ldexp(error_bound,-k); e=k; scale=ldexp(1.0f,e); d=shift(dc,base-e);
            }
        }
    }
    return -1;
}
// Double-single perturbation without exponent bookkeeping in the ordinary
// exponent range. The rescaled kernel handles more extreme zooms.
float fastperturb(device const BLA* table,device const float4* orbit,CX coord,int base,constant Params& p,thread uint& skipped) {
    CX c=shift(coord,base), w=cx(0,0);
    uint r=0, i=0;
    float error_bound=0, cm=sqrt(norm(c));
    while (i<p.limit) {
        if (r+1>=p.count) return -2;
        bool jumped=false;
        if (r>0 && p.leaves>0 && mag(w)<1.6e-12f) {
            float wm=sqrt(norm(w));
            float input_bound=wm+cm+error_bound;
            float remainder_scale=input_bound*input_bound;
            float tolerance=1e-14f*max(wm,cm);
            uint node=p.leaves+r-1;
            while ((node&1)==0 && node>1) node>>=1;
            while (node<p.leaves) {
                BLA b=table[node];
                if (b.steps>1 && i+b.steps<=p.limit && r+b.steps<p.count && wm+error_bound<b.radius && b.quadratic*remainder_scale<tolerance) {
                    error_bound=b.gain*error_bound+b.quadratic*(wm+cm+error_bound)*(wm+cm+error_bound)+2e-14f*(b.gain*wm+mag(unpack(b.b))*cm);
                    w=cadd(product(unpack(b.a),w),product(unpack(b.b),c));
                    r+=b.steps; i+=b.steps; skipped+=b.steps-1; jumped=true; break;
                }
                node*=2;
            }
        }
        if (!jumped) {
            CX z=unpack(orbit[r]);
            float wm=mag(w), zm=mag(z);
            error_bound=2*sqrt(norm(cadd(z,w)))*error_bound+error_bound*error_bound+2e-14f*(2*zm*wm+wm*wm+mag(c));
            w=cadd(product(cadd(times(z,2),w),w),c); ++r; ++i;
        }
        CX z=unpack(orbit[r]), total=cadd(z,w);
        float r2=norm(total);
        if (!isfinite(r2) || !isfinite(error_bound)) return -2;
        float total_error=error_bound+2e-14f*mag(z);
        if (r2>256) return checked_escape(i,r2,total_error);
        if (sqrt(r2)+total_error>=16 || total_error>1) return -2;
        if (r2<1e-6f*norm(z)) return -2;
        if (r2<norm(w) || r+1==p.count) { r=0; w=total; error_bound=total_error+2e-14f*mag(total); }
    }
    return -1;
}
uchar4 color(float s, device const uchar4* lut) {
    if (s<0) return uchar4(17,12,9,255);
    return lut[uint(fract(s*0.026f)*4096.0f)&4095];
}
kernel void mandel(constant Params& p [[buffer(0)]],
                   device const float4* orbit [[buffer(1)]],
                   device float* samples [[buffer(2)]],
                   device uchar4* pixels [[buffer(3)]],
                   device const uchar4* lut [[buffer(4)]],
                   device const BLA* table [[buffer(5)]],
                   device uint* stats [[buffer(6)]],
                   uint2 gid [[thread_position_in_grid]]) {
    uint x=gid.x, y=gid.y+p.first_row;
    if (p.reserved1==1) {
        // Pack the three missing samples of each 2x2 cell into adjacent
        // threads. Simply skipping every fourth lane wastes SIMD work.
        uint reused_corner=((p.width/2)&1)+2*((p.height/2)&1);
        uint corner=gid.x%3;
        if (corner>=reused_corner) ++corner;
        x=(gid.x/3)*2+(corner&1);
        y=p.first_row+gid.y*2+(corner>>1);
    }
    if (x>=p.width || y>=p.height || y>=p.first_row+p.row_count) return;
    uint index=y*p.width+x;
    if (p.reserved1 != 0 && samples[index] != -2) return;
    // Form a double-single quotient to avoid losing sub-pixel coordinate bits.
    float xn=(float(x)+0.5f)-0.5f*float(p.width);
    float yn=0.5f*float(p.height)-(float(y)+0.5f);
    float ix=xn/float(p.width), iy=yn/float(p.width);
    DS dx={ix,fma(-ix,float(p.width),xn)/float(p.width)};
    DS dy={iy,fma(-iy,float(p.width),yn)/float(p.width)};
    DS span={p.mantissa.x,p.mantissa.y};
    CX dc={mul(dx,span),mul(dy,span)};
    uint skipped=0;
    float s=p.shallow==2 ? fastperturb(table,orbit,dc,p.exponent,p,skipped) : p.shallow==1 ? direct(cadd(unpack(p.center),shift(dc,p.exponent)),p.limit) : perturb(orbit,dc,p.exponent,p);
    if (index==0) stats[0]=skipped;
    samples[index]=s; pixels[index]=color(s,lut);
}
