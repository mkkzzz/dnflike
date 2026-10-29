import unittest
from build_dnf_weapon_appearance import bind_image, recipe


class WeaponSourceBinding(unittest.TestCase):
    def test_source_variation_fills_model_and_palette_in_order(self):
        self.assertEqual(bind_image('Character/Swordman/Equipment/Weapon/katana/katana%02d%02dc.img',[3,1]),
                         'sprite/character/swordman/equipment/weapon/katana/katana0301c.img')

    def test_bad_variation_never_falls_back_to_family_zero(self):
        for values in [[],[1],[1,2,3],[True,1],[1.0,2],[-1,2],[100,1]]:
            with self.subTest(values=values), self.assertRaises(ValueError):bind_image('x%02d%02dc.img',values)

    def test_unknown_templates_reject_instead_of_guessing(self):
        for text in ['katana0000c.img','katana%04dc.img','katana%02d%02d%dc.img']:
            with self.subTest(text=text), self.assertRaises(ValueError):bind_image(text,[0,1])

    def test_real_source_front_first_order_is_sorted_for_rendering(self):
        fields=[{'tag':'[variation]','values':[1,1]},
                {'tag':'[layer variation]','values':[2790,'katanac']},
                {'tag':'[equipment ani script]','values':['equipment/character/swordman.lay']},
                {'tag':'[layer variation]','values':[650,'katanab']},
                {'tag':'[equipment ani script]','values':['equipment/character/swordman.lay']}]
        var,layers=recipe(fields)
        self.assertEqual(var,[1,1]);self.assertEqual([v['order'] for v in layers],[650,2790])
        with self.assertRaises(ValueError):recipe(fields+[{'tag':'[variation]','values':[0,0]}])
        with self.assertRaises(ValueError):recipe(fields[:-2])


if __name__=='__main__':unittest.main()
