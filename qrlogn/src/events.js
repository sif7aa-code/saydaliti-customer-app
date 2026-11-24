import { EventEmitter } from 'node:events';

/**
 * ناقل أحداث واحد داخل العملية.
 *
 * كل من ينتج (مراقب Supabase، جسر واتساب) ينشر هنا، وكل من يستهلك
 * (مركز SSE) يشترك هنا. الغرض: فصل الاكتشاف عن التوصيل، حتى لا
 * يعرف المراقب شيئاً عن HTTP ولا يعرف الـhub شيئاً عن الاستطلاع.
 */
class Bus extends EventEmitter {}

export const bus = new Bus();
bus.setMaxListeners(64);

/**
 * أسماء الأحداث. ثابتة في مكان واحد حتى لا يخطئ الطرفان في الاسم
 * بصمت (خطأ اسم = إشعار لا يَصل ولا يُعرف أنه لم يَصل).
 */
export const EV = {
  ORDER_NEW: 'order.new',
  ORDER_STATUS: 'order.status',
  PRICE_CHANGED: 'price.changed',
  PRODUCT_CHANGED: 'product.changed',
  BRAND_CHANGED: 'brand.changed',
  WA_STATE: 'wa.state',
  QR: 'wa.qr',
};

/**
 * يبث حدثاً لكل المشتركين.
 * `audience` يحدد من يستحق: phone محدد، أو دور (driver/admin/customer).
 */
export function publish(topic, payload, audience = { roles: ['customer', 'driver', 'admin'] }) {
  bus.emit('fanout', { topic, payload, audience, at: Date.now() });
}
