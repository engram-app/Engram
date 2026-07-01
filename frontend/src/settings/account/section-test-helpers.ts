import { vi } from "vitest";

// Minimal fake of Clerk's User resource. Override per test as needed.
export function makeUser(overrides: Record<string, unknown> = {}) {
	return {
		firstName: "Ada",
		lastName: "Lovelace",
		imageUrl: "https://example.com/a.png",
		passwordEnabled: true,
		primaryEmailAddressId: "eml_1",
		emailAddresses: [
			{
				id: "eml_1",
				emailAddress: "ada@example.com",
				verification: { status: "verified" },
				destroy: vi.fn().mockResolvedValue({}),
				prepareVerification: vi.fn().mockResolvedValue({}),
				attemptVerification: vi.fn().mockResolvedValue({}),
			},
		],
		externalAccounts: [],
		update: vi.fn().mockResolvedValue({}),
		setProfileImage: vi.fn().mockResolvedValue({}),
		updatePassword: vi.fn().mockResolvedValue({}),
		createEmailAddress: vi
			.fn()
			.mockResolvedValue({
				id: "eml_2",
				emailAddress: "new@example.com",
				prepareVerification: vi.fn().mockResolvedValue({}),
				attemptVerification: vi.fn().mockResolvedValue({}),
			}),
		createExternalAccount: vi
			.fn()
			.mockResolvedValue({
				verification: {
					externalVerificationRedirectURL: new URL("https://accounts.example.com/oauth"),
				},
			}),
		delete: vi.fn().mockResolvedValue({}),
		reload: vi.fn().mockResolvedValue({}),
		...overrides,
	};
}
