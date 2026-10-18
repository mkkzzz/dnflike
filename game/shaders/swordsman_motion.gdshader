shader_type canvas_item;
render_mode unshaded;
// Every source uses the same anatomical triangle mesh. Native colors and alpha
// are sampled together; the replaceable weapon is rendered once outside it.
uniform vec4 weights_a = vec4(1.0,0.0,0.0,0.0);
uniform vec4 weights_b = vec4(0.0);
varying vec4 tint;
uniform sampler2D source_0 : source_color, filter_linear, repeat_disable;
uniform vec4 rect_0=vec4(0.0,0.0,1.0,1.0);
uniform vec2 points_0[32];
varying vec2 sample_uv_0;
uniform sampler2D source_1 : source_color, filter_linear, repeat_disable;
uniform vec4 rect_1=vec4(0.0,0.0,1.0,1.0);
uniform vec2 points_1[32];
varying vec2 sample_uv_1;
uniform sampler2D source_2 : source_color, filter_linear, repeat_disable;
uniform vec4 rect_2=vec4(0.0,0.0,1.0,1.0);
uniform vec2 points_2[32];
varying vec2 sample_uv_2;
uniform sampler2D source_3 : source_color, filter_linear, repeat_disable;
uniform vec4 rect_3=vec4(0.0,0.0,1.0,1.0);
uniform vec2 points_3[32];
varying vec2 sample_uv_3;
uniform sampler2D source_4 : source_color, filter_linear, repeat_disable;
uniform vec4 rect_4=vec4(0.0,0.0,1.0,1.0);
uniform vec2 points_4[32];
varying vec2 sample_uv_4;
uniform sampler2D source_5 : source_color, filter_linear, repeat_disable;
uniform vec4 rect_5=vec4(0.0,0.0,1.0,1.0);
uniform vec2 points_5[32];
varying vec2 sample_uv_5;
uniform sampler2D source_6 : source_color, filter_linear, repeat_disable;
uniform vec4 rect_6=vec4(0.0,0.0,1.0,1.0);
uniform vec2 points_6[32];
varying vec2 sample_uv_6;
uniform sampler2D source_7 : source_color, filter_linear, repeat_disable;
uniform vec4 rect_7=vec4(0.0,0.0,1.0,1.0);
uniform vec2 points_7[32];
varying vec2 sample_uv_7;
void vertex() {
 tint=COLOR;
 int point_id=int(UV.x+0.1);
 sample_uv_0=(points_0[point_id]*512.0-rect_0.xy)/max(rect_0.zw,vec2(1.0));
 sample_uv_1=(points_1[point_id]*512.0-rect_1.xy)/max(rect_1.zw,vec2(1.0));
 sample_uv_2=(points_2[point_id]*512.0-rect_2.xy)/max(rect_2.zw,vec2(1.0));
 sample_uv_3=(points_3[point_id]*512.0-rect_3.xy)/max(rect_3.zw,vec2(1.0));
 sample_uv_4=(points_4[point_id]*512.0-rect_4.xy)/max(rect_4.zw,vec2(1.0));
 sample_uv_5=(points_5[point_id]*512.0-rect_5.xy)/max(rect_5.zw,vec2(1.0));
 sample_uv_6=(points_6[point_id]*512.0-rect_6.xy)/max(rect_6.zw,vec2(1.0));
 sample_uv_7=(points_7[point_id]*512.0-rect_7.xy)/max(rect_7.zw,vec2(1.0));
}
vec4 sampled(sampler2D tex,vec2 uv) {
 if(any(lessThan(uv,vec2(0.0)))||any(greaterThan(uv,vec2(1.0))))return vec4(0.0);
 vec4 c=texture(tex,uv);return vec4(c.rgb*c.a,c.a);
}
void fragment() {
 vec4 sum=vec4(0.0);
 if(weights_a[0]>0.00001)sum+=sampled(source_0,sample_uv_0)*weights_a[0];
 if(weights_a[1]>0.00001)sum+=sampled(source_1,sample_uv_1)*weights_a[1];
 if(weights_a[2]>0.00001)sum+=sampled(source_2,sample_uv_2)*weights_a[2];
 if(weights_a[3]>0.00001)sum+=sampled(source_3,sample_uv_3)*weights_a[3];
 if(weights_b[0]>0.00001)sum+=sampled(source_4,sample_uv_4)*weights_b[0];
 if(weights_b[1]>0.00001)sum+=sampled(source_5,sample_uv_5)*weights_b[1];
 if(weights_b[2]>0.00001)sum+=sampled(source_6,sample_uv_6)*weights_b[2];
 if(weights_b[3]>0.00001)sum+=sampled(source_7,sample_uv_7)*weights_b[3];
 COLOR=vec4(sum.rgb/max(sum.a,0.0000001),sum.a)*tint;
}
