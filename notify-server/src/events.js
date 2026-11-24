import { EventEmitter } from 'node:events';

/**
 * ناقل أحداث العملية الواحدة.
 * كل من ينتج ينشر هنا، ومن يستهلك يشترك. يفصل الاكتشاف عن التوصيل.
 */
class Bus extends EventEmitter {}

export const bus = new Bus();
bus.setMaxListeners(64);

export const EV = {
  ORDER_NEW: 'order.new',
  ORDER_STATUS: 'order.status',
  PRICE_CHANGED: 'price.changed',
  PRODUCT_CHANGED: 'product.changed',
  PRODUCT_DELETED: 'product.deleted',
  ORDER_ITEM_REMOVED: 'order.item_removed',
  BRAND_CHANGED: 'brand.changed',
};

const ROLES = new Set(['customer', 'driver', 'admin', 'shop_owner']);

/**
 * يبث حدثاً لكل المشتركين المؤهلين.
 *
 * audience: { phones: [...] } أو { roles: [...] }
 * الدلالة "أو": إن حُدّد أرقام فالرقم هو الفيصل، وإلا فالدور.
 */
export function publish(topic, payload, audience = { roles: ['customer', 'driver', 'admin'] }) {
  bus.emit('fanout', { topic, payload, audience, at: Date.now() });
}

export const parseRoles = (raw) =>
  String(raw || 'customer')
    .split(',')
    .map((r) => r.trim())
    .filter((r) => ROLES.has(r));

export const isValidRole = (r) => ROLES.has(r);
