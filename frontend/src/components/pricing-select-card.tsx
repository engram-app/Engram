export { PricingSelectCardGrid, type PricingSelectCardGridProps } from "./pricing-select-card-grid";
export {
	PricingSelectCardGroup,
	type PricingSelectCardGroupProps,
} from "./pricing-select-card-group";
export {
	PricingSelectCardStacked,
	type PricingSelectCardStackedProps,
} from "./pricing-select-card-stacked";

/**
 * Plan configuration for use with PricingSelectCardGroup and ExpressCheckout.
 * Maps to a single Paddle price ID — pass an array of these to describe
 * the selectable plans in a checkout or pricing selector.
 */
export type PricingSelectPlan = {
	priceId: string;
	name: string;
	description?: string;
	badge?: string;
	icon?: React.ReactNode;
};
